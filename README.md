# luci-app-prio

给 OpenWrt / ImmortalWrt 用的**设备优先级**插件。

按设备把下行、上行流量分成 3 / 4 / 8 个优先级带，用 `tc htb` + `sch_ets`（严格优先）+
`fq_codel` 调度，让"打游戏的设备"在"别人下载/上传"时仍然保持低延迟。界面全中文。

```
带 0  >  带 1  >  带 2（只拿剩余）
```

[![CI](https://github.com/fyhbauyg/luci-app-prio/actions/workflows/ci.yml/badge.svg)](https://github.com/fyhbauyg/luci-app-prio/actions/workflows/ci.yml)
[![Release](https://github.com/fyhbauyg/luci-app-prio/actions/workflows/release.yml/badge.svg)](https://github.com/fyhbauyg/luci-app-prio/actions/workflows/release.yml)
[![latest release](https://img.shields.io/github/v/release/fyhbauyg/luci-app-prio?label=release)](https://github.com/fyhbauyg/luci-app-prio/releases)

## 界面

[![LuCI 配置页面](docs/img/luci.jpg)](docs/img/luci.jpg)

<sub>点击看原图。状态区同时在报"总闸 246.8 Mbit/s / 低优先带阀门 197.3 Mbit/s"、
当前 RTT 和队列是否空闲。</sub>

## 效果

下面两张截图是**同一时刻、两台设备同时开测速**的结果——截图时间都是 18:27，
一台在优先级带 0，一台在优先级带 2，两台互相抢同一条 5G-A 线路。
**注意：两台是同时测的，不是先后测的。**

| 带 0（最高优先级） | 带 2（最低优先级） |
|:---:|:---:|
| <img src="docs/img/band0.jpg" width="320" alt="带 0 设备同时测速"> | <img src="docs/img/band2.jpg" width="320" alt="带 2 设备同时测速"> |
| 下行 **95.07** Mbit/s<br>上行 **124.22** Mbit/s<br>ping **28** ms | 下行 **39.26** Mbit/s<br>上行 **15.53** Mbit/s<br>ping **33** ms |

当时路由器上的状态：总闸 246.8 Mbit/s、低优先带阀门 197.3 Mbit/s、安全余量 20%、
上行实测 171.1 Mbit/s、3 个带、2 层严格优先。

两台加起来 134 Mbit/s，都还在总闸之下，所以带 2 也没有被"惩罚"到几乎没网——
真正的差别是**带 0 在抢带宽的时候 ping 只有 28 ms**，而不是几秒钟。

> 说明：带 0 不限速是刻意的。它的作用是在别人下载时保住低延迟，
> 不是把别人的带宽掐死。

## 为什么需要它

普通的路由器限速（或单纯开个 qdisc）在 5G-A / 5G 这类"模组自带大缓冲"的线路上是无效的：
只要不限速，包装满运营商的缓冲网络，队列根本不在路由器里，优先级就无从谈起。

实测（NRadio C2000-MAX，5G-A 插卡，同一批下载流量）：

| 路由器下行限速 | 到公网的往返延迟 |
|---|---|
| 20 Mbit/s | **1068 ms** |
| 14 Mbit/s | **1670 ms** |
| 8 Mbit/s | **32 ms** |
| 5 Mbit/s | **31 ms** |
| 0.5 Mbit/s（几乎空闲） | **30 ms** |

也就是说：**限速必须低于线路真实能力**，队列才会留在路由器里。而这个"真实能力"
在 5G-A 线路上会在一个小时内从 161 Mbit/s 掉到 8 Mbit/s —— 任何静态数字都会有一段时间是错的。

所以本插件把两件事分开做：

- **容量靠实测**：路由器用固件自带的测速客户端（`cnspeedtest`，自动挑大陆节点，
  多线程并发）跑一次，**实测值原样作为总闸**。这是唯一能把速率**调高**的途径。
  低优先带的阀门 = `总闸 × (100 − 安全余量)%`，带 0 不设阀门。
- **延迟只负责下调**：空闲时用 ping 的最小值学一个延迟基线；有流量时每约 20 秒测一次
  平均值，超过基线 + 300 ms 就按超出量把限速下调 **10%–30%**，其余时间不动。
  三个窗口都收不到回包时判定探测目标不可用，不继续下调，而是安排一次新的实测。

自动抬速**不存在**：延迟只能说明"有队列"，永远说明不了"能装多少比特"——这是四轮
审计给出的同一个结论。

上传打满 45 Mbit/s 时，ping 仍为 21–85 ms（之前是 1.7 秒）。

## 下载

所有版本都在 [Releases](https://github.com/fyhbauyg/luci-app-prio/releases) 里，
每个版本带两个包（`all` 架构，任何 OpenWrt 设备都能装）：

| 文件 | 用途 |
|---|---|
| `luci-app-prio-*.apk` | 插件本体（引擎 + 页面 + 菜单 + ACL） |
| `luci-i18n-prio-zh-cn-*.apk` | 中文翻译 |

`lmo` 二进制不能跨 LuCI 版本复用，所以翻译包是按编译时的 luci feed 版本号命名的；
版本号对不上时自己从源码编一遍即可（见下）。

## 要求

- OpenWrt / ImmortalWrt 21.02 以上（apk 与 opkg 均可），已在 ImmortalWrt 25.12 / kernel 6.12 / MT7987B 上验证
- 依赖：`tc-full`、`kmod-sched-core`、`kmod-sched`、`luci-compat`
  （`sch_htb` / `sch_fq_codel` 由 `kmod-sched-core` 提供，`kmod-sched` 会带上 `sch_ets`）
- 可选：`cnspeedtest`（固件自带，用于实测容量；没有时回退到内置的 HTTP 测速）
- 可选：`curl` + `jq`（内置 HTTP 测速回退要用；`cnspeedtest` 存在时不需要）
- 可选：`traceroute`（只用于"挑选探测目标"按钮；没装时按钮自动隐藏，不影响其它功能）
- **必须关掉硬件 HNAT**（插件会自动切换成软件流量分载，否则 qdisc 被绕过）

## 安装

```sh
apk add --allow-untrusted --force-overwrite luci-app-prio-*.apk
apk add --allow-untrusted --force-overwrite luci-i18n-prio-zh-cn-*.apk
/etc/init.d/prio reload
```

opkg 系统把 `apk add` 换成 `opkg install`。然后在 LuCI 里打开
「网络 → 设备优先级」，勾选**启用设备优先级**，保存。

### 从源码编译

把整个目录放进 OpenWrt 源码树的 `package/custom/luci-app-prio`，然后：

```sh
make package/luci-app-prio/compile V=s
```

产物在 `bin/packages/<arch>/base/luci-app-prio-*.apk`。

## 配置项

| 选项 | 说明 |
|---|---|
| `enabled` | 总开关。关闭时恢复原来的加速模式 |
| `auto_hnat_off` | 强制使用软件流量分载（默认 1，必须开） |
| `auto_bandwidth` | 自动调速（延迟闭环）。关闭后使用固定的 `shaper_kbit` |
| `rtt_target` | 延迟探测目标。必须是**公网**地址，表单会拒绝内网/回环地址 |
| `shaper_margin` | 低优先带的余量百分数：带 0 不设限，其余带按 (100 − 此值)% 封顶（0–50） |
| `shaper_kbit` | 固定下行速率（`auto_bandwidth=0` 时使用；自动模式下被忽略） |
| `uplink_kbit` | 上行整形速率。0 = 自动（先测量再整形）；填 ≥1000 则固定用这个值 |
| `bands` | 优先级带数量：3 / 4 / 8 |
| `strict_bands` | 严格优先的层数。3 带时填 2 = 带 0 > 带 1 > 带 2 |
| `fq_codel` | 每带加 fq_codel，防止单条流饿死同带其它流 |
| `lan_shaping` / `lan_rate_kbit` | 是否对局域网内流量也排队 |
| `wan_iface` / `lan_iface` | 挂载点，默认 `eth2` / `br-lan` |

设备列表里每个设备填 IPv4、选优先级带（上传和下载共用；想分开设就在上面打开
"分开设置上传优先级"）。不在列表里的设备同样会经过整形器，落到"未列出设备的优先级"。

## 自测

仓库里带了逐项 PASS/FAIL 的自测脚本：绝大部分是只读检查，但**会**临时改写上行
速率、清空学习值（相当于手动删掉学习到的速率）并跑一次实测容量（快线上约 300 MB 流量），结束时恢复原值：

```sh
sh tools/prio-selftest.sh
```

覆盖：服务状态、上下行 qdisc/class/ets/fq_codel 结构、速率与配置一致性、延迟基线、
nft 标记与 IPv6 集合、探测目标可达性、实测容量命令与记录、清空学习值、停止/启动、
LuCI 模型语法、中文翻译、以及"后台进程不会改回自动开关"。

## 工作原理

```
下行 (br-lan)
  htb 1: root
   ├ 1:1    10Gbit          ← 不带标记的流量（局域网）
   └ 1:100  <总闸>           ← 互联网流量，= 上一次实测容量
        └ ets 2: bands N strict K
             ├ 2:1  带 0    ← 直挂 fq_codel，不设阀门，可吃满总闸
             ├ 2:2  带 1 → 21: htb <阀门>
             └ 2:3  带 2 → 22: htb <阀门>

上行 (eth2) 结构相同：1:100 是上行总闸，低优先带各自挂在 21: / 22: 阀门下
```

总闸跟实测容量走，**阀门只压低压带**（带 0 没有阀门类）。
分类在 NAT **之前**用 nftables 给包打 `fwmark`，因此分类结果在地址转换后依然有效；
IPv6 地址从邻居表定期补进 nft set。

## 版本与发布

版本号形如 `1.0.0-r110`，tag 形如 `v1.0.0-r110`。

- CI（[.github/workflows/ci.yml](.github/workflows/ci.yml)）：每次 push 检查 shell 语法
  （`sh` 与 `busybox ash` 各一遍）、`shellcheck`、Lua 语法、JSON 合法性、`msgfmt` 翻译检查。
- 发布（[.github/workflows/release.yml](.github/workflows/release.yml)）：打 tag 自动发版，
  或者到 Actions 页面手动跑一次 `Release` 并填 tag。产物取自 `dist/`（编译机产出的
  `all` 架构包），附 `sha256sums.txt`。

## 已知限制

- 延迟基线只在线路空闲时学习。如果长时间不间断有流量，控制器会短暂"冻结"（不动作，也不会乱调）
- 实测容量只在线路空闲时进行（会占用几秒带宽，实测约 100–200 MB 流量）
- 上行整形默认自动：在测到三次干净的上传窗口之前，上行是不限速的（队列会落在模组里）
- 上行种子只接受"模组没有堆积"的窗口（窗口内 RTT 未超过基线 +80 ms），
  取三个窗口的中间值作为总闸（带 0 可用满），低优先带再按 `shaper_margin` 压到 (100 − m)%，
  这样带 0 能跑满实测容量，低优先带仍然待在延迟拐点之下
- 手动「立即测量」在别人用网时也会跑：它把同期线路上的背景流量加回结果里，
  背景超过结果的 1/4 就丢弃这次样本；自动测量仍然只在空闲时跑
- 严格优先层数设得越多，低优先级带越容易被饿死（3 带 + 2 层严格时，带 2 只拿剩余）

## 更新日志

### r114

- 拿不到锁的测量不再 `uci commit`（并发保存会把配置文件覆盖成旧版本），改成只
  `uci set`，由下一个持锁的流程落盘
- 测速的临时文件从 `/tmp/.prio-*` 挪进 `/var/run/luci-app-prio/`：`/tmp` 是人人可写
  的，固定的文件名可以被预先做成符号链接，让 root 截断任意文件
- 测速节点名来自服务端，写 syslog 之前先过滤控制字符（否则能伪造日志行）
- 看门狗同时检查 WAN 和 LAN 的队列：4G 重拨时 netifd 会重建 `eth2` 并带走它的
  qdisc，之前只有 LAN 会自愈，上行就一直不限速
- 上行阀门类建不起来时不再静默跳过，写 `uplink:fail` 让 `start()` 失败

### r113

- 「自动挑选最近的节点」改成后台执行：一次 traceroute 加最多四次 ping，在差的
  路由上要二十秒，之前会把整个页面卡住；现在点完刷新一次就能看到新目标
- `shaper_kbit` / `uplink_kbit` 加了上限，超了直接拒绝（之前多打几个零会让引擎
  先算出天文数字再丢给 tc）
- `strict_bands` 大于 `bands-1` 时按 `bands-1` 显示并保存（之前下拉显示 1 级、
  下面「实际生效顺序」那行显示 2 级，一保存就把严格层级丢了）
- LAN 和 WAN 选成同一个接口时当场拦住（之前保存成功、引擎拒绝启动，真正原因
  只写在 `/var/run/luci-app-prio/err` 里）
- 清掉 tbf 时代的死代码（`TBF_HANDLE`、`valve_kbit()`），文件头注释改成真实层级
- `qdisc_is_ours` 不再匹配 `ets 1:`——这个句柄本插件从来没创建过，只会把别人
  的队列认成自己的

### r112

- 状态行不再互相踩：改下行速率时不会删掉上行的阀门行，上行也只写一行
  （之前 `upvalve` 会写两行，一行总闸一行阀门）
- 原地改速率被内核拒绝时不再对外宣布新速率，并置 `downlink:fail`
- 停探测/刷新前先确认 pid 还是自己的（pid 复用会误杀无关进程）
- 锁目录里没有 pid 文件时 5 秒后回收（之前永远清不掉，之后每次 start 空等 30 秒）
- 测量标记的有效期按 `measure_secs` 推算（原来固定 120 秒，短于一次合法测量）
- 忙闲守卫同时看 tx（之前只看 rx，别人在上传时会被判成"线路空闲"）
- 掉线期间 `err` 文件超过 64 KB 自动截断（之前会一直涨，住在 tmpfs 里）
- 从流量播种速率后进入静默窗口（之前同一窗口的 RTT 会立刻把刚播下的速率砍掉 10–30%）
- 换 `wan_iface` / `lan_iface` 时拆掉旧接口上的队列（之前会残留到下次重启）
- 安全余量的输入范围改成 0–50，与引擎一致（之前填 80 能存进去，实际只按 50 算）

### r111

- 一次性速率迁移的标记从 tmpfs 挪进 uci。之前每次重启都会重跑，把上行总闸按
  `100/(100-安全余量)` 放大一次，没有上限
- `nft` 建表失败不再静默：`start` 直接失败并在状态里留 `nft:fail`，不再出现
  "零整形、页面全绿"
- 上行树在速率未知时建成（没有阀门类），之后学到速率只做 `tc class change` 会
  一直失败；现在发现阀门类缺失就补建
- `stop()` 的拆除动作进锁，不再和还没等到 HNAT 下线的 `start()` 互相覆盖
- 关掉下行整形后，测量不会再把它装回来
- 手动「立即测量」不再被"线路忙"挡住：允许跑，并把背景流量加回结果，
  背景过大（> 结果 1/4）才丢弃。自动测量仍然只在空闲时跑
- 接口名白名单校验：`wan_iface` / `lan_iface` 只能是网络设备名
- ACL 去掉 `/etc/init.d/prio` 的 write+exec（受限账号不该能改写 root 脚本）
- `band` / `band_up` 越界时按引擎规则夹取，`band_up` 增加"与下载相同"这一项
- 自测：阀门类按 `bands` 校验数量、状态行真的逐项检查、FAIL 时退出码为 1

### r110

- 总闸 = 实测容量原值，只有低优先带按 `shaper_margin` 设阀门，带 0 不设
- 测量的忙闲阈值改为上次容量的 2%（原来是固定 2 Mbit/s）
- 原地改速率后状态行的 `shaper` / `valve` 同步刷新

## License

Apache-2.0
