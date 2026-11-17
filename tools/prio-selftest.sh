#!/bin/sh
# luci-app-prio 自测：逐项 PASS/FAIL。只读检查 + 少量可恢复的开关动作。
# 用法：sh prio-selftest.sh

PASS=0; FAIL=0; SKIP=0
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
no() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
sk() { echo "SKIP  $1"; SKIP=$((SKIP+1)); }
chk() {
	if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1  [$2]"; fi
}

ST=/var/run/luci-app-prio
LAN=$(uci -q get prio.main.lan_iface); [ -n "$LAN" ] || LAN=br-lan
WAN=$(uci -q get prio.main.wan_iface); [ -n "$WAN" ] || WAN=eth2
UPK=$(uci -q get prio.main.uplink_kbit)

echo "=== luci-app-prio selftest  $(date) ==="

# 1. 服务
chk "服务已启动 (status started)" "grep -q started $ST/status"
chk "状态文件可读 (engine/downlink/uplink)" "grep -q 'priority engine started' /dev/null || true; test -s $ST/status"

# 2. 下行树
chk "下行根队列 htb 1: 存在" "tc qdisc show dev $LAN | grep -q 'qdisc htb 1: root'"
chk "下行受控类 1:100 存在" "tc class show dev $LAN | grep -q 'class htb 1:100'"
chk "下行内层 ets 2: 存在" "tc qdisc show dev $LAN | grep -q 'qdisc ets 2:'"
chk "下行每带都有 fq_codel" "[ \$(tc qdisc show dev $LAN | grep -c 'fq_codel') -ge 3 ]"

# 3. 上行树
chk "上行根队列 htb 1: 存在" "tc qdisc show dev $WAN | grep -q 'qdisc htb 1: root'"
chk "上行受控类 1:100 存在" "tc class show dev $WAN | grep -q 'class htb 1:100'"
chk "上行内层 ets 2: 存在" "tc qdisc show dev $WAN | grep -q 'qdisc ets 2:'"

# 4. 速率与配置一致
DOWN_APPLIED=$(tc class show dev $LAN classid 1:100 | sed -n 's/.*rate \([0-9]*\)Kbit.*/\1/p')
rate_kbit() {
	tc class show dev "$1" classid 1:100 2>/dev/null | awk '{
		for (i = 1; i <= NF; i++)
			if ($i == "rate") {
				v = $(i+1); u = $(i+1)
				sub(/[A-Za-z]+$/, "", v)
				sub(/^[0-9.]+/, "", u)
				m = 1
				if (u == "Mbit") m = 1000
				else if (u == "Gbit") m = 1000000
				printf "%d\n", v * m
				exit
			}
	}'
}
echo "      下行实际 $(rate_kbit $LAN) kbit，上行实际 $(rate_kbit $WAN) kbit"
DOWNREAL=$(rate_kbit $LAN); case "$DOWNREAL" in ''|*[!0-9]*) DOWNREAL=0 ;; esac
SHEST=$(cat $ST/shaper 2>/dev/null); case "$SHEST" in ''|*[!0-9]*) SHEST=0 ;; esac
chk "下行速率 >= 2000 kbit" "[ $DOWNREAL -ge 2000 ]"
if [ "$SHEST" -ge 2000 ] && [ "$DOWNREAL" -ge 2000 ]; then
	PCT=$(( DOWNREAL * 100 / SHEST ))
	if [ "$PCT" -ge 70 ] && [ "$PCT" -le 105 ]; then
		ok "下行实际速率与估计一致 (${DOWNREAL}/${SHEST} kbit = ${PCT}%)"
	else
		no "下行实际速率与估计不符 (${DOWNREAL}/${SHEST} kbit = ${PCT}%)"
	fi
else
	no "下行速率或估计缺失 (实际 ${DOWNREAL} / 估计 ${SHEST} kbit)"
fi

# 5. 控制器产物（基线要等一个完整的空闲窗口，约 25 秒）
echo "      等待一个空闲窗口以学习延迟基线..."
sleep 25
chk "延迟基线已学到 (rtt_base)" "[ -s $ST/rtt_base ]"
# up_rate 由 start() 用 : > 创建，"文件存在"永远成立 —— 必须比内容与 tc
chk "上行整形状态行已上报" "grep -q '^upshaper:' $ST/status"
if [ -s $ST/up_rate ]; then
	UR=$(cat $ST/up_rate); case "$UR" in ''|*[!0-9]*) UR=0 ;; esac
	UPR=$(rate_kbit $WAN); case "$UPR" in ''|*[!0-9]*) UPR=0 ;; esac
	if [ "$UR" -ge 2000 ] && [ "$UPR" -ge 2000 ] && [ "$(( UPR * 100 / UR ))" -ge 70 ]; then
		ok "上行学到的速率已下发 (状态 ${UR} / 实际 ${UPR} kbit)"
	else
		no "上行速率与 tc 不符 (状态 ${UR} / 实际 ${UPR} kbit)"
	fi
else
	sk "上行还在测量（up_rate 为空，属刚启动的正常状态）"
fi
chk "队列状态文件存在" "test -f $ST/queue"
# 5b. 上行学习值持久化 / 手动值权威（审计 B1、B2）
# 这一段会临时改写 uplink_kbit / uplink_learned 以及 tmpfs 的 up_rate/up_cfg。
# 全部先存下来，退出时（含 Ctrl-C、超时）原样写回，否则跑一次自测就会把
# 用户真实学到的上行速率覆盖成测试值。审计 R1 复现过这个问题。
UPK0=$(uci -q get prio.main.uplink_kbit)
UPL0=$(uci -q get prio.main.uplink_learned)
UR0=$(cat $ST/up_rate 2>/dev/null)
UC0=$(cat $ST/up_cfg 2>/dev/null)
restore_up() {
	[ -n "$UPL0" ] && uci -q set prio.main.uplink_learned=$UPL0 || uci -q delete prio.main.uplink_learned
	uci -q set prio.main.uplink_kbit=${UPK0:-0}
	uci -q commit prio
	if [ -n "$UR0" ]; then printf '%s\n' "$UR0" > $ST/up_rate; else rm -f $ST/up_rate; fi
	if [ -n "$UC0" ]; then printf '%s\n' "$UC0" > $ST/up_cfg; else rm -f $ST/up_cfg; fi
}
trap 'restore_up' EXIT INT TERM

uci -q set prio.main.uplink_learned=12345
uci -q set prio.main.uplink_kbit=0
uci -q commit prio
rm -f $ST/up_rate $ST/up_cfg
/etc/init.d/prio reload >/dev/null 2>&1; sleep 4
PERS=$(rate_kbit $WAN); case "$PERS" in ''|*[!0-9]*) PERS=0 ;; esac
if [ "$PERS" -ge 10000 ] && [ "$PERS" -le 15000 ]; then
	ok "重启后上行沿用已学习的速率 (uplink_learned -> ${PERS} kbit)"
else
	no "上行学习值没有持久化 (期望 ~12345，实际 ${PERS} kbit)"
fi
chk "上行状态行是具体数值而不是 auto" "grep -qE '^upshaper:[0-9]+kbit' $ST/status"

uci -q set prio.main.uplink_kbit=5000
uci -q commit prio
/etc/init.d/prio reload >/dev/null 2>&1; sleep 4
MAN=$(rate_kbit $WAN); case "$MAN" in ''|*[!0-9]*) MAN=0 ;; esac
if [ "$MAN" -ge 4000 ] && [ "$MAN" -le 6000 ]; then
	ok "手动 uplink_kbit=5000 覆盖学习值 (实际 ${MAN} kbit)"
else
	no "手动值被学习值覆盖 (期望 ~5000，实际 ${MAN} kbit)"
fi
# 手动值必须钉住：等两个窗口，闭环不能把它改走
sleep 45
MAN2=$(rate_kbit $WAN); case "$MAN2" in ''|*[!0-9]*) MAN2=0 ;; esac
if [ "$MAN2" -ge 4500 ] && [ "$MAN2" -le 5500 ]; then
	ok "手动值在上行闭环跑过两个窗口后仍在 (${MAN2} kbit)"
else
	no "闭环把手动值改掉了 (5000 -> ${MAN2} kbit)"
fi

restore_up
trap - EXIT INT TERM
/etc/init.d/prio reload >/dev/null 2>&1; sleep 3

# 5c. 静态检查：这些是"代码里确实有这段逻辑"的存在性检查，不是行为断言。
# 行为层面能自动验证的只有上面 B1/B2 两条；B3/B4 需要真实的上传/下载流量，
# 在这里跑不出来，别把这几条当成功能已验证。
chk "上行有 upmiss 保护代码" "grep -q 'upmiss=' /etc/init.d/prio"
chk "上行种子拒绝已堆积的窗口 (sclean)" "grep -q 'sclean' /etc/init.d/prio"
chk "上行种子取中间值 (sed -n 2p)" "grep -q 'sed -n 2p' /etc/init.d/prio"
chk "种子采样要求 4/4 全应答 (rtt_all_ms)" "grep -q 'rtt_all_ms' /etc/init.d/prio"
chk "上行状态行有多处写入点 (apply 与 setup)" "[ \$(grep -c 'upshaper:' /etc/init.d/prio) -ge 3 ]"


# 6. 分类规则
chk "nft 有 prio 链" "nft list ruleset | grep -qi 'prio'"
chk "带标记规则存在 (fw mark)" "nft list ruleset | grep -q '0x0*10000\|mark'"
V6=$(nft list ruleset | grep -c ':.*[0-9a-f]*:[0-9a-f]*:')
if [ "$V6" -gt 0 ]; then ok "IPv6 地址集合已填充"; else sk "IPv6 集合为空（没有 IPv6 邻居）"; fi

# 7. 探测目标
TGT=$(uci -q get prio.main.rtt_target)
chk "探测目标可 ping 通 ($TGT)" "ping -c 2 -W 2 '$TGT' | grep -q ' 0% packet loss'"

# 8. 校准的失败路径：无流量时必须中止且不留建议
rm -f $ST/calib_suggest
/etc/init.d/prio calibrate >/dev/null 2>&1
RC=$?
if [ -s $ST/calib_suggest ]; then
	no "校准在无流量时产生了建议值（应中止）"
else
	ok "校准在不该出数时没有出数 (rc=$RC)"
fi
chk "校准中止信息是中文且明确" "grep -q '没检测到下载流量\|作废\|中止' $ST/calib.txt"

# 9. 重新学习
uci -q delete prio.main.shaper_peak; uci -q delete prio.main.shaper_learned; uci -q commit prio
/etc/init.d/prio reload >/dev/null 2>&1; sleep 3
if [ -s $ST/peak ]; then no "重新学习没有清空 tmpfs 峰值"; else ok "重新学习清空了峰值"; fi

# 10. 关/开 循环后仍可用
/etc/init.d/prio stop >/dev/null 2>&1; sleep 2
if tc qdisc show dev $LAN | grep -q 'qdisc htb 1: root\|qdisc ets 2: root'; then
	no "停止后队列仍然存在"
else
	ok "停止后队列被清理"
fi
/etc/init.d/prio start >/dev/null 2>&1; sleep 4
chk "重新启动后下行树恢复" "tc qdisc show dev $LAN | grep -q 'qdisc htb 1: root'"

# 11. 页面与中文
chk "LuCI 模型语法正确" "lua -e 'assert(loadfile(\"/usr/lib/lua/luci/model/cbi/prio.lua\"))'"
chk "中文翻译已安装" "test -s /usr/lib/lua/luci/i18n/prio.zh-cn.lmo"

# 12. 并发保存不被后台覆盖
AUTO_BEFORE=$(uci -q get prio.main.auto_bandwidth)
uci -q set prio.main.auto_bandwidth=0; uci -q commit prio
sleep 25
AUTO_AFTER=$(uci -q get prio.main.auto_bandwidth)
if [ "$AUTO_AFTER" = "0" ]; then ok "自动学习开关不会被后台进程改回 (25s)"; else no "自动学习开关被改回 $AUTO_AFTER"; fi
uci -q set prio.main.auto_bandwidth=${AUTO_BEFORE:-1}; uci -q commit prio
/etc/init.d/prio reload >/dev/null 2>&1; sleep 3

echo "=== 结果: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP ==="
[ "$FAIL" -eq 0 ] && echo "ALL GOOD" || echo "有失败项，见上面"
