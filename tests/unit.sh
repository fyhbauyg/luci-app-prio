#!/bin/sh
# Behavioural tests for the engine, with no router involved.
#
# The engine is POSIX sh that talks to uci, tc, nft and logger. Stub those four
# on PATH, source the script, and the parts that are decisions -- the valve
# arithmetic, the status file bookkeeping, the lock, the "is this queue ours"
# check -- run anywhere. That is where the bugs were: a one-shot marker in
# tmpfs, a status row that deleted its neighbour, an upvalve written twice.
#
#   sh tests/unit.sh          # exits non-zero on failure
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ENGINE="$HERE/../root/etc/init.d/prio"
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t prio)
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"
RUN="$WORK/run"
mkdir -p "$BIN" "$RUN"
export PRIO_UCI_DB="$WORK/uci.db"
export PRIO_TC_LOG="$WORK/tc.log"
export PRIO_TC_SHOW="$WORK/tcshow.txt"
: > "$PRIO_UCI_DB"; : > "$PRIO_TC_LOG"; : > "$PRIO_TC_SHOW"

cat > "$BIN/uci" <<'STUB'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
get)
	sed -n "s|^$1=||p" "$PRIO_UCI_DB" 2>/dev/null | tail -n 1 | {
		read -r v || exit 1
		[ -n "$v" ] || exit 1
		printf '%s\n' "$v"
	} ;;
set)
	k="${1%%=*}"; v="${1#*=}"
	{ grep -v "^$k=" "$PRIO_UCI_DB" 2>/dev/null; printf '%s=%s\n' "$k" "$v"; } \
		> "$PRIO_UCI_DB.new" && mv "$PRIO_UCI_DB.new" "$PRIO_UCI_DB" ;;
commit|reload) : ;;
*) exit 1 ;;
esac
STUB

cat > "$BIN/tc" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PRIO_TC_LOG"
case "${1:-} ${2:-}" in
"qdisc show"|"class show") cat "$PRIO_TC_SHOW" 2>/dev/null; exit 0 ;;
esac
exit 0
STUB

cat > "$BIN/nft" <<'STUB'
#!/bin/sh
printf 'nft %s\n' "$*" >> "$PRIO_TC_LOG"
exit 0
STUB

cat > "$BIN/logger" <<'STUB'
#!/bin/sh
printf 'log %s\n' "$*" >> "$PRIO_TC_LOG"
exit 0
STUB

chmod 755 "$BIN"/*

# /lib/functions.sh is rc.common's; only these four are used by the engine.
cat > "$WORK/functions.sh" <<'STUB'
config_load() { CFGNAME="$1"; }
_cfg_get() {
	_v=$(uci -q get "${CFGNAME:-prio}.$1.$2" 2>/dev/null)
	[ -n "${_v:-}" ] || _v="$3"
	printf '%s' "$_v"
}
config_get() { eval "$1=\$(_cfg_get "$2" "$3" "${4:-}")"; }
config_get_bool() {
	_v=$(_cfg_get "$2" "$3" "${4:-}")
	case "$_v" in
	1|on|true|enabled|yes) _v=1 ;;
	0|off|false|disabled|no) _v=0 ;;
	*) _v="${4:-0}" ;;
	esac
	eval "$1=\$_v"
}
STUB

PATH="$BIN:$PATH"
export PATH
. "$WORK/functions.sh"
# The engine assigns these at load time; point them at the sandbox afterwards.
. "$ENGINE"
PRIO_STATE="$RUN"
DETECT_PID="$PRIO_STATE/detect.pid"
PRIO_LOCK="$PRIO_STATE/lock"
LOCK_HELD=0

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }

echo "=== engine unit tests ($(basename "$ENGINE")) ==="

# ---- valve arithmetic -----------------------------------------------------
uci set prio.main.shaper_margin=20
eq "margin 20 percent"          "$(margin_pct)" "20"
eq "valve is 80 percent"        "$(valve_of 125000)" "100000"
eq "valve floor is 2000"        "$(valve_of 2000)" "2000"
eq "valve never exceeds gate"   "$(valve_of 1000)" "1000"
eq "valve of nothing is 0"      "$(valve_of 0)" "0"
uci set prio.main.shaper_margin=80
eq "margin above 50 clamps"     "$(margin_pct)" "50"
uci set prio.main.shaper_margin=garbage
eq "margin garbage falls back"  "$(margin_pct)" "10"
uci set prio.main.shaper_margin=20

# ---- status file bookkeeping ---------------------------------------------
st="$PRIO_STATE/status"
printf 'downlink:ok\nuplink:ok\nshaper:100000kbit\nvalve:80000kbit\nupvalve:50000kbit\nstarted\n' > "$st"
refresh_status_rate shaper 125000 100000
eq "downlink rewrites shaper"   "$(sed -n 's/^shaper://p' "$st")" "125000kbit"
eq "downlink rewrites valve"    "$(sed -n 's/^valve://p' "$st")" "100000kbit"
eq "downlink keeps upvalve"     "$(sed -n 's/^upvalve://p' "$st")" "50000kbit"
eq "downlink keeps other rows"  "$(grep -c '^started$' "$st")" "1"

refresh_status_rate upvalve 163000 130400
eq "uplink writes one upvalve"  "$(grep -c '^upvalve:' "$st")" "1"
eq "uplink upvalve is the valve" "$(sed -n 's/^upvalve://p' "$st")" "130400kbit"
eq "uplink leaves shaper alone" "$(sed -n 's/^shaper://p' "$st")" "125000kbit"
eq "uplink leaves valve alone"  "$(sed -n 's/^valve://p' "$st")" "100000kbit"

# ---- the queue is ours, and only ours ------------------------------------
printf 'qdisc htb 1: root refcnt 2 r2q 10 default 1 direct_packets_stat 0\n' > "$PRIO_TC_SHOW"
if qdisc_is_ours br-test; then ok "htb 1: is ours"; else no "htb 1: is ours"; fi
printf 'qdisc ets 1: root refcnt 2 bands 3\n' > "$PRIO_TC_SHOW"
if qdisc_is_ours br-test; then no "ets 1: is not ours"; else ok "ets 1: is not ours"; fi
printf 'qdisc fq_codel 0: root\n' > "$PRIO_TC_SHOW"
if qdisc_is_ours br-test; then no "foreign qdisc is not ours"; else ok "foreign qdisc is not ours"; fi

# ---- the lock ------------------------------------------------------------
rm -rf "$PRIO_LOCK"
if acquire_lock; then ok "lock acquired"; else no "lock acquired"; fi
if acquire_lock; then ok "lock is re-entrant"; else no "lock is re-entrant"; fi
release_lock
eq "lock released" "$([ -d "$PRIO_LOCK" ] && echo yes || echo no)" "no"

mkdir -p "$PRIO_LOCK"; printf '999999\n' > "$PRIO_LOCK/pid"
if acquire_lock; then ok "dead owner is reclaimed"; else no "dead owner is reclaimed"; fi
release_lock

rm -rf "$PRIO_LOCK"; mkdir -p "$PRIO_LOCK"
start=$(date +%s)
if acquire_lock; then
	span=$(( $(date +%s) - start ))
	if [ "$span" -lt 20 ]; then ok "ownerless lock is reclaimed (${span}s)"
	else no "ownerless lock is reclaimed (${span}s)"; fi
else
	no "ownerless lock is reclaimed"
fi
release_lock

echo "=== PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
