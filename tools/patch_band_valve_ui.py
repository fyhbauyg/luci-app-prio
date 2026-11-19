#!/usr/bin/env python3
"""r109 UI/docs half of the per-band valve change.

Same rule as patch_band_valve.py: every replacement must match exactly once, so
a rename in the source cannot silently leave half the strings behind.
"""
import sys

def load(p):
    with open(p, encoding="utf-8", newline="") as f:
        return f.read()

def save(p, s):
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(s)

def sub_once(text, old, new, tag):
    n = text.count(old)
    if n != 1:
        sys.stderr.write("FAIL %s: expected 1, found %d\n" % (tag, n))
        sys.exit(1)
    print("ok  " + tag)
    return text.replace(old, new)

# ------------------------------------------------------------------- lua ----
P = "luasrc/model/cbi/prio.lua"
s = load(P)

old = """\tlocal applied = r
\tif auto == "1" then
\t\tapplied = math.floor(r * (100 - m) / 100)
\tend
\tif auto == "1" and m > 0 then
\t\t-- No format specifier inside the translatable string: a translator
\t\t-- who "fixes" %d%% to %d would make string.format raise and take the
\t\t-- whole page down. Build it instead.
\t\treturn string.format("%.1f Mbit/s (%s %.1f, %s %d%%)",
\t\t\tapplied / 1000, translate("estimate"), r / 1000,
\t\t\ttranslate("headroom"), m)
\tend"""
new = """\t-- The estimate is the total gate; the margin only caps the bands below the
\t-- top one. Both numbers are built here instead of as format specifiers
\t-- inside the translatable string, because a translator who "fixes" %d%% to
\t-- %d would make string.format raise and take the whole page down.
\tlocal cap = math.floor(r * (100 - m) / 100)
\tif auto == "1" and m > 0 then
\t\treturn string.format("%s %.1f / %s %.1f Mbit/s",
\t\t\ttranslate("Total"), r / 1000,
\t\t\ttranslate("Lower bands"), cap / 1000)
\tend"""
s = sub_once(s, old, new, "lua summary")

old = """o = s:option(Value, "shaper_margin", translate("Safety margin (%)"))
o.default = 10
o.datatype = "range(0,100)"
o.rmempty = false
o.description = translate("How far below the measured capacity to run, in percent. " ..
\t"Only the measured value is reduced; a rate typed in by hand is used exactly as " ..
\t"typed. Bigger means a deeper local queue (priority bites harder) but less peak " ..
\t"throughput.")"""
new = """o = s:option(Value, "shaper_margin", translate("Lower-band headroom (%)"))
o.default = 10
o.datatype = "range(0,100)"
o.rmempty = false
o.description = translate("The measured capacity is the total gate and the top band " ..
\t"is never capped. Every lower band is capped at (100 - this)% of it: 20 leaves " ..
\t"them at 80%. A larger number deepens the local queue (priority bites harder) but " ..
\t"lowers their peak throughput.")"""
s = sub_once(s, old, new, "lua margin option")
save(P, s)

# -------------------------------------------------------------------- po ----
P = "po/zh_Hans/prio.po"
s = load(P)

s = sub_once(s,
    'msgid "Safety margin (%)"\nmsgstr "安全余量（%）"',
    'msgid "Lower-band headroom (%)"\nmsgstr "低优先带余量（%）"',
    "po margin label")

s = sub_once(s,
    'msgid "How far below the measured capacity to run, in percent. Only the measured value is reduced; a rate typed in by hand is used exactly as typed. Bigger means a deeper local queue (priority bites harder) but less peak throughput."\n'
    'msgstr "在实测能力之下留多少余量，按百分比。只对测量出来的值打折；手填的速率原样下发。数值越大，路由器里的队列越深、优先级越硬，但峰值带宽越少。"',
    'msgid "The measured capacity is the total gate and the top band is never capped. Every lower band is capped at (100 - this)% of it: 20 leaves them at 80%. A larger number deepens the local queue (priority bites harder) but lowers their peak throughput."\n'
    'msgstr "实测容量就是总闸，顶级带完全不限速；其余每个带按（100 − 此值）% 封顶，填 20 就是压到 80%。数值越大，路由器里的队列越深、优先级越硬，但低优先带的峰值带宽越少。"',
    "po margin description")

# New msgids used by the summary line, inserted in alphabetical position after
# "Latency floor" is not guaranteed, so append before the trailing blank of the
# last entry instead: a missing msgid would render the English source on a
# Chinese page.
s = sub_once(s,
    'msgid "Uplink rate (kbit/s)"',
    'msgid "Lower bands"\nmsgstr "低优先带"\n\n'
    'msgid "Total"\nmsgstr "总闸"\n\n'
    'msgid "Uplink rate (kbit/s)"',
    "po new msgids")
save(P, s)

# --------------------------------------------------------------- Makefile ---
P = "Makefile"
s = load(P)
s = sub_once(s, "PKG_RELEASE:=108", "PKG_RELEASE:=109", "Makefile release")
save(P, s)

# ----------------------------------------------------------------- README ---
P = "README.md"
s = load(P)
s = sub_once(s,
    "| `shaper_margin` | 只对自动学到的速率生效，手动填的速率原样下发（0–50） |",
    "| `shaper_margin` | 低优先带的余量百分数：带0 不设限，其余带按 (100 − 此值)% 封顶（0–50） |",
    "README config row")
s = sub_once(s,
    "  取三个窗口的中间值再打 `shaper_margin` 折让，避免一次突发把限速设到真实容量之上",
    "  取三个窗口的中间值作为总闸（带0 可用满），低优先带再按 `shaper_margin` 压到 (100 − m)%，\n"
    "  这样带0 能跑满实测容量，低优先带仍然待在延迟拐点之下",
    "README measurement text")
save(P, s)

# ---------------------------------------------------------------- selftest --
P = "tools/prio-selftest.sh"
s = load(P)
s = sub_once(s,
    'chk "下行内层 ets 2: 存在" "tc qdisc show dev $LAN | grep -q \'qdisc ets 2:\'"',
    'chk "下行内层 ets 2: 存在" "tc qdisc show dev $LAN | grep -q \'qdisc ets 2:\'"\n'
    'chk "下行带1/带2 阀门类存在" "tc class show dev $LAN | grep -q \'class htb 21:1\'"',
    "selftest downlink valve")
s = sub_once(s,
    'chk "上行内层 ets 2: 存在" "tc qdisc show dev $WAN | grep -q \'qdisc ets 2:\'"',
    'chk "上行内层 ets 2: 存在" "tc qdisc show dev $WAN | grep -q \'qdisc ets 2:\'"\n'
    'chk "上行带1/带2 阀门类存在" "tc class show dev $WAN | grep -q \'class htb 21:1\'"',
    "selftest uplink valve")
save(P, s)

print("done")
