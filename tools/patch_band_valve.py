#!/usr/bin/env python3
"""r109: per-band valves.

Old model: one global shaped rate = estimate * (100 - margin) / 100.
New model: the total gate is the estimate itself; every band except the top one
gets an HTB valve at estimate * (100 - margin) / 100. The top band is unshaped
inside the ETS scheduler, so it may use the whole measured capacity.

Every replacement is asserted to happen exactly once: a silent miss here would
produce a script that looks patched but still shapes the old way.
"""
import re
import sys

PATH = "root/etc/init.d/prio"


def sub_once(text, old, new, tag):
    n = text.count(old)
    if n != 1:
        sys.stderr.write("FAIL %s: expected 1 occurrence, found %d\n" % (tag, n))
        sys.exit(1)
    print("ok  %s" % tag)
    return text.replace(old, new)


s = open(PATH, encoding="utf-8").read()

# ---------------------------------------------------------------- helpers ----
helpers_old = """\tm="$(margin_pct)"
\techo $(( est * (100 - m) / 100 ))
}

# Rate for the LAN class."""

helpers_new = """\tm="$(margin_pct)"
\techo $(( est * (100 - m) / 100 ))
}

# Valve for every band except the top one: the same number the old code handed
# to tc as the global shaped rate (estimate minus the safety margin). The margin
# no longer comes off the total, so the top band may use the whole measured
# capacity while every lower band is held below the knee.
valve_of() {
\tlocal r="$1" m v
\tcase "$r" in ''|*[!0-9]*) r=0 ;; esac
\t[ "$r" -ge 1000 ] 2>/dev/null || { echo 0; return 0; }
\tm="$(margin_pct)"
\tv=$(( r * (100 - m) / 100 ))
\t[ "$v" -lt 2000 ] && v=2000
\t[ "$v" -gt "$r" ] && v="$r"
\techo "$v"
}

# Total gate handed to tc verbatim.
total_kbit() {
\tshaper_kbit
}

valve_kbit() {
\tvalve_of "$(total_kbit)"
}

# Per-band valve: every band except the top one gets its own HTB class capped at
# $valve, so a lower band can never take the whole line. The top band stays
# unshaped inside the ETS scheduler and may reach the total gate.
add_band_valves() {
\tlocal dev="$1" bands="$2" valve="$3"
\tlocal b vh vb
\t[ "$valve" -ge 1000 ] 2>/dev/null || return 0
\t[ "$bands" -gt 1 ] 2>/dev/null || return 0
\tb=1
\twhile [ "$b" -lt "$bands" ]; do
\t\tvh=$((20 + b))
\t\tvb=$(( valve / 8 * 20 ))
\t\t[ "$vb" -lt 8192 ] && vb=8192
\t\t[ "$vb" -gt 128000 ] && vb=128000
\t\ttc qdisc add dev "$dev" parent "2:$((b + 1))" handle "${vh}:" htb default 1 2>>"$PRIO_STATE/err"
\t\ttc class add dev "$dev" parent "${vh}:" classid "${vh}:1" htb \\
\t\t\trate "${valve}kbit" ceil "${valve}kbit" burst "${vb}b" cburst "${vb}b" 2>>"$PRIO_STATE/err"
\t\tb=$((b + 1))
\tdone
\treturn 0
}

# Rate changes must not rebuild the tree, so the valves are changed in place.
set_band_valves() {
\tlocal dev="$1" bands="$2" valve="$3"
\tlocal b vh vb
\t[ "$valve" -ge 1000 ] 2>/dev/null || return 0
\tb=1
\twhile [ "$b" -lt "$bands" ]; do
\t\tvh=$((20 + b))
\t\tvb=$(( valve / 8 * 20 ))
\t\t[ "$vb" -lt 8192 ] && vb=8192
\t\t[ "$vb" -gt 128000 ] && vb=128000
\t\ttc class change dev "$dev" parent "${vh}:" classid "${vh}:1" htb \\
\t\t\trate "${valve}kbit" ceil "${valve}kbit" burst "${vb}b" cburst "${vb}b" 2>>"$PRIO_STATE/err"
\t\tb=$((b + 1))
\tdone
\treturn 0
}

# Rate for the LAN class."""
s = sub_once(s, helpers_old, helpers_new, "helpers")

# ------------------------------------------------------------ band_leaves ----
leaves_old = """band_leaves() {
\tlocal dev="$1" bands="$2" handle="${3:-1}"
\tlocal fq
\tfq="$(state_get fq_codel)"
\t[ -n "$fq" ] || fq=1
\t[ "$fq" = "1" ] || return 0"""
leaves_new = """band_leaves() {
\tlocal dev="$1" bands="$2" handle="${3:-1}" valve="${4:-0}"
\tlocal fq p
\tfq="$(state_get fq_codel)"
\t[ -n "$fq" ] || fq=1
\t[ "$fq" = "1" ] || return 0"""
s = sub_once(s, leaves_old, leaves_new, "band_leaves signature")

leaves_loop_old = """\tlocal i=1
\twhile [ "$i" -le "$bands" ]; do
\t\ttc qdisc add dev "$dev" parent "${handle}:$i" fq_codel target 3ms 2>>"$PRIO_STATE/err"
\t\ti=$((i + 1))
\tdone
}"""
leaves_loop_new = """\tlocal i=1
\twhile [ "$i" -le "$bands" ]; do
\t\t# Band 1 (index 0) is never valved, so its leaf hangs directly off the
\t\t# ETS band; the others hang off the HTB class that enforces the valve.
\t\tif [ "$i" -gt 1 ] && [ "$valve" -ge 1000 ] 2>/dev/null; then
\t\t\tp="$((19 + i)):1"
\t\telse
\t\t\tp="${handle}:$i"
\t\tfi
\t\ttc qdisc add dev "$dev" parent "$p" fq_codel target 3ms 2>>"$PRIO_STATE/err"
\t\ti=$((i + 1))
\tdone
}"""
s = sub_once(s, leaves_loop_old, leaves_loop_new, "band_leaves loop")

# ------------------------------------------------------------ setup_downlink -
dl_decl_old = """setup_downlink() {
\tlocal dev="$1" bands="$2"
\tlocal rate applied
\trate="$(shaper_kbit)"
\tapplied="$(applied_kbit "$rate")"
"""
dl_decl_new = """setup_downlink() {
\tlocal dev="$1" bands="$2"
\tlocal rate applied valve
\trate="$(shaper_kbit)"
\tapplied="$(total_kbit)"
\tvalve="$(valve_of "$applied")"
"""
s = sub_once(s, dl_decl_old, dl_decl_new, "setup_downlink decl")

dl_ets_old = """\t\tif ! tc qdisc add dev "$dev" parent 1:100 handle 2: ets bands "$bands" strict "$(strict_count "$bands")" 2>>"$PRIO_STATE/err"; then
\t\t\ttc qdisc del dev "$dev" root 2>/dev/null
\t\t\techo "downlink:fail" >> "$PRIO_STATE/status"
\t\t\treturn 1
\t\tfi
\t\techo "shaper:${applied}kbit" >> "$PRIO_STATE/status\""""
dl_ets_new = """\t\tif ! tc qdisc add dev "$dev" parent 1:100 handle 2: ets bands "$bands" strict "$(strict_count "$bands")" 2>>"$PRIO_STATE/err"; then
\t\t\ttc qdisc del dev "$dev" root 2>/dev/null
\t\t\techo "downlink:fail" >> "$PRIO_STATE/status"
\t\t\treturn 1
\t\tfi
\t\tadd_band_valves "$dev" "$bands" "$valve"
\t\techo "shaper:${applied}kbit" >> "$PRIO_STATE/status"
\t\techo "valve:${valve}kbit" >> "$PRIO_STATE/status\""""
s = sub_once(s, dl_ets_old, dl_ets_new, "setup_downlink ets+status")

dl_leaves_old = """\tband_leaves "$dev" "$bands" 2
\tsetup_filters "$dev" "$bands" 2
\t# "ok" used to be written even on the classification-only path"""
dl_leaves_new = """\tband_leaves "$dev" "$bands" 2 "$valve"
\tsetup_filters "$dev" "$bands" 2
\t# "ok" used to be written even on the classification-only path"""
s = sub_once(s, dl_leaves_old, dl_leaves_new, "setup_downlink band_leaves")

# -------------------------------------------------------------- setup_uplink -
ul_decl_old = """setup_uplink() {
\tlocal dev="$1" bands="$2"
\tlocal rate applied
"""
ul_decl_new = """setup_uplink() {
\tlocal dev="$1" bands="$2"
\tlocal rate applied valve
"""
s = sub_once(s, ul_decl_old, ul_decl_new, "setup_uplink decl")

ul_valve_old = """\tlocal upauto=0
\tif [ "$applied" -lt 1000 ]; then
\t\tapplied=1000000
\t\tupauto=1
\tfi
"""
ul_valve_new = """\tlocal upauto=0
\tvalve=0
\tif [ "$applied" -lt 1000 ]; then
\t\tapplied=1000000
\t\tupauto=1
\telse
\t\tvalve="$(valve_of "$applied")"
\tfi
"""
s = sub_once(s, ul_valve_old, ul_valve_new, "setup_uplink valve seed")

ul_ets_old = """\tband_leaves "$dev" "$bands" 2
\tsetup_filters "$dev" "$bands" 2
\techo "uplink:ok" >> "$PRIO_STATE/status\""""
ul_ets_new = """\tadd_band_valves "$dev" "$bands" "$valve"
\tband_leaves "$dev" "$bands" 2 "$valve"
\tsetup_filters "$dev" "$bands" 2
\techo "upvalve:${valve}kbit" >> "$PRIO_STATE/status"
\techo "uplink:ok" >> "$PRIO_STATE/status\""""
s = sub_once(s, ul_ets_old, ul_ets_new, "setup_uplink valves")

# ----------------------------------------------------------------- apply_rate -
apply_old = """apply_rate() {
\tlocal dev="$1" rate
\trate="$(applied_kbit "$2")"
\tlocal burst=$((rate / 8 * 20))
\t[ "$burst" -lt 8192 ] && burst=8192
\t[ "$burst" -gt 256000 ] && burst=256000
\ttc class change dev "$dev" parent 1: classid 1:100 \\
\t\thtb rate "${rate}kbit" ceil "${rate}kbit" \\
\t\tburst "${burst}b" cburst "${burst}b" 2>>"$PRIO_STATE/err"
}"""
apply_new = """apply_rate() {
\tlocal dev="$1" rate="$2"
\tlocal burst valve bands
\tcase "$rate" in ''|*[!0-9]*) rate=0 ;; esac
\tbands="$(state_get bands)"
\tcase "$bands" in 3|4|8) ;; *) bands=3 ;; esac
\tburst=$((rate / 8 * 20))
\t[ "$burst" -lt 8192 ] && burst=8192
\t[ "$burst" -gt 256000 ] && burst=256000
\ttc class change dev "$dev" parent 1: classid 1:100 \\
\t\thtb rate "${rate}kbit" ceil "${rate}kbit" \\
\t\tburst "${burst}b" cburst "${burst}b" 2>>"$PRIO_STATE/err"
\tvalve="$(valve_of "$rate")"
\tset_band_valves "$dev" "$bands" "$valve"
}"""
s = sub_once(s, apply_old, apply_new, "apply_rate")

# ----------------------------------------------------------- apply_uplink_rate -
apul_old = """apply_uplink_rate() {
\tlocal dev="$1" rate="$2"
\tlocal burst=$((rate / 8 * 20))
\t[ "$burst" -lt 8192 ] && burst=8192
\t[ "$burst" -gt 128000 ] && burst=128000
\ttc class change dev "$dev" parent 1: classid 1:100 \\
\t\thtb rate "${rate}kbit" ceil "${rate}kbit" \\
\t\tburst "${burst}b" cburst "${burst}b" 2>>"$PRIO_STATE/err" || return 1"""
apul_new = """apply_uplink_rate() {
\tlocal dev="$1" rate="$2"
\tlocal burst valve bands
\tcase "$rate" in ''|*[!0-9]*) rate=0 ;; esac
\tbands="$(state_get bands)"
\tcase "$bands" in 3|4|8) ;; *) bands=3 ;; esac
\tburst=$((rate / 8 * 20))
\t[ "$burst" -lt 8192 ] && burst=8192
\t[ "$burst" -gt 128000 ] && burst=128000
\ttc class change dev "$dev" parent 1: classid 1:100 \\
\t\thtb rate "${rate}kbit" ceil "${rate}kbit" \\
\t\tburst "${burst}b" cburst "${burst}b" 2>>"$PRIO_STATE/err" || return 1
\tvalve="$(valve_of "$rate")"
\tset_band_valves "$dev" "$bands" "$valve\""""
s = sub_once(s, apul_old, apul_new, "apply_uplink_rate")

# --------------------------------------------------- detector: uplink seeding -
seed_old = """\t\t\t\t\tif [ "$nup" -ge 3 ] && [ "$useed" -ge 3000 ]; then
\t\t\t\t\t\tumarg=$(margin_pct)
\t\t\t\t\t\tuseed=$(( useed * (100 - umarg) / 100 ))
\t\t\t\t\t\t[ "$useed" -lt 2000 ] && useed=2000"""
seed_new = """\t\t\t\t\tif [ "$nup" -ge 3 ] && [ "$useed" -ge 3000 ]; then
\t\t\t\t\t\t# Raw sample: the margin is applied to the
\t\t\t\t\t\t# lower bands by apply_uplink_rate, not here.
\t\t\t\t\t\t[ "$useed" -lt 2000 ] && useed=2000"""
s = sub_once(s, seed_old, seed_new, "uplink seed margin")

# ------------------------------------------------ measurement: uplink store ----
merge_old = """\t\t\t# The uplink has no margin anywhere else in the chain, so it is
\t\t\t# applied here: shaping at the measured value itself puts the queue
\t\t\t# straight back into the modem.
\t\t\tlocal um ulshape
\t\t\tum="$(margin_pct)"
\t\t\tulshape=$(( ul * (100 - um) / 100 ))
\t\t\t[ "$ulshape" -lt 2000 ] && ulshape=2000"""
merge_new = """\t\t\t# The measured upload is the total gate. apply_uplink_rate()
\t\t\t# derives the lower-band valve from it, so the margin is no
\t\t\t# longer taken off here.
\t\t\tlocal ulshape
\t\t\tulshape=$ul
\t\t\t[ "$ulshape" -lt 2000 ] && ulshape=2000"""
s = sub_once(s, merge_old, merge_new, "measurement uplink store")

# -------------------------------------------------------------- migration ----
mig_old = """\tmkdir -p "$PRIO_STATE" 2>/dev/null
\tacquire_lock || return 1
"""
mig_new = """\tmkdir -p "$PRIO_STATE" 2>/dev/null
\tacquire_lock || return 1

\t# One-shot migration from the old "margin on the total" model. The stored
\t# uplink numbers were already reduced by the margin; the new model stores
\t# the raw capacity and takes the margin off the lower bands only. Scaling
\t# them back once keeps the first window after the upgrade at the same real
\t# rate instead of losing the margin twice.
\tif [ ! -f "$PRIO_STATE/ratemodel" ]; then
\t\tlocal mp ulv urv
\t\tmp="$(margin_pct)"
\t\tulv="$(state_get uplink_learned)"
\t\tcase "$ulv" in ''|*[!0-9]*) ulv=0 ;; esac
\t\tif [ "$ulv" -ge 1000 ]; then
\t\t\tstate_set uplink_learned $(( ulv * 100 / (100 - mp) ))
\t\tfi
\t\turv="$(cat "$PRIO_STATE/up_rate" 2>/dev/null)"
\t\tcase "$urv" in ''|*[!0-9]*) urv=0 ;; esac
\t\tif [ "$urv" -ge 1000 ]; then
\t\t\tprintf '%s\\n' $(( urv * 100 / (100 - mp) )) > "$PRIO_STATE/up_rate" 2>/dev/null
\t\tfi
\t\tprintf '2\\n' > "$PRIO_STATE/ratemodel" 2>/dev/null
\tfi
"""
s = sub_once(s, mig_old, mig_new, "migration")

open(PATH, "w", encoding="utf-8", newline="\n").write(s)
print("patched %s" % PATH)
