#!/usr/bin/env python3
"""r110: the "line is busy" guard was tuned for a 20 Mbit 4G line.

An absolute 2000 kbit/s threshold is 10% of such a line, but only 0.8% of a
267 Mbit/s one -- so ordinary background traffic (a phone scrolling, a thumbnail
download) blocked every measurement and the button looked dead. Make the
threshold proportional to the last estimate (2%, floored at 2 Mbit) and record
the observed rate so the page can say what blocked it.
"""
import sys

def load(p):
    return open(p, encoding="utf-8", newline="").read()

def save(p, s):
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(s)

def once(s, old, new, tag):
    n = s.count(old)
    if n != 1:
        sys.stderr.write("FAIL %s: expected 1, found %d\n" % (tag, n))
        sys.exit(1)
    print("ok  " + tag)
    return s.replace(old, new)

# ------------------------------------------------------------------ script ---
P = "root/etc/init.d/prio"
s = load(P)

s = once(s, """mea_fail() {
\tmkdir -p "$PRIO_STATE" 2>/dev/null
\tprintf '%s %s\\n' "${MEASURE_NOW:-$(date +%s)}" "$1" > "$PRIO_STATE/measure_err" 2>/dev/null
}""",
"""mea_fail() {
\tmkdir -p "$PRIO_STATE" 2>/dev/null
\t# Optional extra fields: line-busy carries "observed threshold" in kbit so
\t# the page can say how much traffic blocked the run instead of only that
\t# something did.
\tlocal extra
\textra=""
\t[ -n "$2" ] && extra=" $2"
\t[ -n "$3" ] && extra="$extra $3"
\tprintf '%s %s%s\\n' "${MEASURE_NOW:-$(date +%s)}" "$1" "$extra" > "$PRIO_STATE/measure_err" 2>/dev/null
}""", "mea_fail extra args")

s = once(s, """\tlocal i0 i1
\ti0=$(cat "/sys/class/net/$dev/statistics/rx_bytes" 2>/dev/null)
\tsleep 2
\ti1=$(cat "/sys/class/net/$dev/statistics/rx_bytes" 2>/dev/null)
\tcase "$i0$i1" in ''|*[!0-9]*) ;; *)
\t\tif [ $(( (i1 - i0) * 8 / 2 / 1000 )) -gt 2000 ]; then
\t\t\techo "measure:busy"
\t\t\tlogger -t luci-app-prio "measurement skipped: link is busy"
\t\t\tmea_fail line-busy
\t\t\treturn 1
\t\tfi
\t\t;;
\tesac""",
"""\tlocal i0 i1 bobs bthr
\ti0=$(cat "/sys/class/net/$dev/statistics/rx_bytes" 2>/dev/null)
\tsleep 2
\ti1=$(cat "/sys/class/net/$dev/statistics/rx_bytes" 2>/dev/null)
\tcase "$i0$i1" in ''|*[!0-9]*) ;; *)
\t\tbobs=$(( (i1 - i0) * 8 / 2 / 1000 ))
\t\t# Proportional threshold. A flat 2000 kbit/s was 10% of the 20 Mbit
\t\t# 4G line this feature was written for, but only 0.8% of a 267 Mbit
\t\t# line: there, a phone scrolling a feed already exceeds it and the
\t\t# button can never run. 2% of the last estimate keeps the guard real
\t\t# while letting ordinary background traffic through.
\t\tbthr=$(( $(shaper_kbit) / 50 ))
\t\t[ "$bthr" -lt 2000 ] && bthr=2000
\t\tif [ "$bobs" -gt "$bthr" ]; then
\t\t\techo "measure:busy"
\t\t\tlogger -t luci-app-prio "measurement skipped: link is busy (${bobs} kbit/s > ${bthr})"
\t\t\tmea_fail line-busy "$bobs" "$bthr"
\t\t\treturn 1
\t\tfi
\t\t;;
\tesac""", "proportional busy guard")
save(P, s)

# --------------------------------------------------------------------- lua ---
P = "luasrc/model/cbi/prio.lua"
s = load(P)

s = once(s, """\t\tlocal ets, code = (fs.readfile("/var/run/luci-app-prio/measure_err") or ""):match("^(%d+)%s+(%S+)")
\t\tets = tonumber(ets) or 0""",
"""\t\tlocal ets, code, rest = (fs.readfile("/var/run/luci-app-prio/measure_err") or ""):match("^(%d+)%s+(%S+)%s*(.*)")
\t\tets = tonumber(ets) or 0
\t\tlocal obs, thr = (rest or ""):match("^(%d+)%s+(%d+)")
\t\tobs, thr = tonumber(obs), tonumber(thr)""", "lua parse extras")

s = once(s, """\t\telseif code == "line-busy" then
\t\t\twhy = translate("the line was busy, so it was skipped")""",
"""\t\telseif code == "line-busy" then
\t\t\twhy = translate("the line was busy, so it was skipped")
\t\t\t-- Numbers only, no new msgids: the English text above has a
\t\t\t-- compiled translation, and a fresh one would render English on a
\t\t\t-- Chinese page until the next i18n rebuild.
\t\t\tif obs and thr and thr > 0 then
\t\t\t\twhy = string.format("%s · %.1f/%.1f Mbit/s", why, obs / 1000, thr / 1000)
\t\t\tend""", "lua line-busy numbers")
save(P, s)

# ---------------------------------------------------------------- selftest ---
P = "tools/prio-selftest.sh"
s = load(P)
s = once(s, 'chk "上行状态由 setup 与 apply 两处写入"',
         'chk "线路忙的阈值按容量比例而不是写死 2000" "grep -q \'shaper_kbit) / 50\' /etc/init.d/prio"\n'
         'chk "上行状态由 setup 与 apply 两处写入"', "selftest proportional guard")
save(P, s)

print("done")
