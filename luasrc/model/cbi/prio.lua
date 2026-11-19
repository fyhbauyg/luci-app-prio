-- Copyright 2026 congge
local m, s, o, d, i
local uci = require "luci.model.uci".cursor()
local fs = require "nixio.fs"
local sys = require "luci.sys"
-- luci.http: the auto-refresh row has to know whether this request is the
-- "Measure now" POST, because the marker is created by a detached child that
-- has not started yet when this model is loaded.
local http = require "luci.http"

local function str(v)
	return type(v) == "string" and v or ""
end

local function get_bands()
	local ok, b = pcall(function() return uci:get("prio", "main", "bands") end)
	b = ok and tonumber(b) or 3
	if b ~= 3 and b ~= 4 and b ~= 8 then b = 3 end
	return b
end

local function read_leases()
	local out = {}
	local fh = io.open("/tmp/dhcp.leases", "r")
	if not fh then return out end
	for line in fh:lines() do
		local ts, mac, ip, host = line:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
		if type(ip) == "string" and ip:match("^%d+%.%d+%.%d+%.%d+$") then
			local name = (type(host) == "string" and host ~= "*" and host ~= "")
				and host or ip
			out[#out + 1] = { ip = ip, name = name, mac = mac or "" }
		end
	end
	fh:close()
	return out
end

local function read_static_hosts()
	local out = {}
	local ok, all = pcall(function() return uci:get_all("dhcp") end)
	if not ok or type(all) ~= "table" then return out end
	for _, sec in pairs(all) do
		if type(sec) == "table" and sec[".type"] == "host" then
			local ip = str(sec.ip)
			if ip:match("^%d+%.%d+%.%d+%.%d+$") then
				local name = str(sec.name)
				if name == "" then name = ip end
				out[#out + 1] = { ip = ip, name = name, mac = str(sec.mac) }
			end
		end
	end
	return out
end

-- Set of IPs claimed by static DHCP hosts. Only these are skipped in the lease
-- list below; the leases themselves must still be listed or the device
-- dropdown would show nothing on a normal router (dhcp has few static hosts).
local function ip_index()
	local map = {}
	for _, t in ipairs(read_static_hosts()) do map[t.ip] = true end
	return map
end

m = Map("prio", translate("Device Priority"),
	translate("Give selected devices network priority. The downlink shaper limits the " ..
		"connection below the line's real speed so the router can queue and reorder " ..
		"packets; it measures the line itself, or you type the rate in once and " ..
		"use a fixed rate. Packets are marked before NAT so the classification survives " ..
		"address translation."))

-- ============================================================
-- 运行状态
-- ============================================================
s = m:section(SimpleSection, nil, translate("Runtime Status"))
s.anonymous = true

-- The status file is written by the init script, but it can go stale (a qdisc
-- removed by another package, a start lost to a racing save). Cross-checking
-- the kernel keeps the page from claiming "running" when nothing is queued.
local function lan_name()
	local ok, v = pcall(function() return uci:get("prio", "main", "lan_iface") end)
	if ok and type(v) == "string" and v ~= "" then return v end
	return "br-lan"
end

-- One fork per page: several rows ask the kernel the same question.
local tc_cache = nil
local function tc_show()
	if tc_cache then return tc_cache end
	tc_cache = sys.exec("tc qdisc show dev " .. lan_name() .. " 2>/dev/null") or ""
	return tc_cache
end

local function qdisc_present()
	local out = tc_show()
	return out:find("qdisc htb 1: root") ~= nil or out:find("qdisc ets 2: root") ~= nil
end

-- A classification-only tree (ets 2: root) looks "running" but has no queue, so
-- the bands cannot reorder anything. That state must not be reported as healthy.
local function htb_present()
	return tc_show():find("qdisc htb 1: root") ~= nil
end

local function engine_state()
	local c = ""
	if fs.access("/var/run/luci-app-prio/status") then
		c = fs.readfile("/var/run/luci-app-prio/status") or ""
	end
	local started = c:find("started") ~= nil
	local queued = qdisc_present()
	if started and queued then return translate("Running") end
	if started and not queued then return translate("Running (queue rebuilding)") end
	if queued then return translate("Running") end
	return translate("Stopped")
end

o = s:option(DummyValue, "_engine")
o.title = translate("Engine")
o.cfgvalue = function()
	local st = engine_state()
	local ok, en = pcall(function() return uci:get("prio", "main", "enabled") end)
	if en == "1" and st == translate("Stopped") then
		st = st .. translate(" -- the switch is on but the engine is not running; save once to re-apply")
	end
	return st
end

o = s:option(DummyValue, "_accel")
o.title = translate("Acceleration mode")
o.cfgvalue = function()
	-- The effective mode is what the kernel is really doing. On this board the
	-- authoritative value is the marker the c2000max-hnat controller writes;
	-- the TurboACC UCI option is only the request. Reading UCI alone made this
	-- row claim "Hardware HNAT" while the hook was already down.
	local fp = ""
	if fs.access("/var/run/c2000max-hnat-effective") then
		fp = (fs.readfile("/var/run/c2000max-hnat-effective") or ""):gsub("%s+$", "")
	end
	-- "unknown" is what the vendor controller writes while it is converging
	-- (and what it leaves behind when it bails out early). Show the requested
	-- mode instead of a word that means nothing to the user.
	local state_note = ""
	if fp == "" or fp == "unknown" then
		state_note = (fp == "unknown") and translate(" (controller state unknown)") or ""
		local ok, v = pcall(function() return uci:get("turboacc", "config", "fastpath") end)
		fp = (ok and v) or "?"
	end
	local ok2, hook = pcall(function() return fs.readfile("/sys/kernel/debug/hnat/hook_toggle") end)
	hook = ok2 and (hook or ""):gsub("%s+$", "") or "?"
	local map = {
		mediatek_hnat   = translate("Hardware HNAT"),
		flow_offloading = translate("Software flow offloading"),
		disabled        = translate("Disabled"),
	}
	-- The debugfs hook reports raw kernel words ("disabled", "enabled", "0",
	-- "1"). Printing them as-is was the last English left on a Chinese page.
	local hookmap = {
		["disabled"] = translate("Disabled"),
		["enabled"]  = translate("Enabled"),
		["0"]        = translate("Disabled"),
		["1"]        = translate("Enabled"),
		["off"]      = translate("Disabled"),
		["on"]       = translate("Enabled"),
	}
	return string.format("%s / %s: %s%s",
		map[fp] or fp, translate("hardware hook"), hookmap[hook] or hook, state_note)
end

o = s:option(DummyValue, "_shaper")
o.title = translate("Downlink shaper")
o.cfgvalue = function()
	local r = 0
	if fs.access("/var/run/luci-app-prio/shaper") then
		-- gsub returns (result, count); the extra parens keep only the result,
		-- otherwise tonumber() would treat the count as a base.
		local raw = fs.readfile("/var/run/luci-app-prio/shaper") or ""
		raw = (raw:gsub("%s+", ""))
		r = tonumber(raw) or 0
	end
	local ok0, auto = pcall(function() return uci:get("prio", "main", "auto_bandwidth") end)
	local src = translate("live")
	if r < 1000 and auto == "1" then
		local ok1, learned = pcall(function() return uci:get("prio", "main", "shaper_learned") end)
		r = ok1 and tonumber(learned) or 0
		src = translate("learned")
	end
	if r < 1000 then
		local ok, cfg = pcall(function() return uci:get("prio", "main", "shaper_kbit") end)
		r = ok and tonumber(cfg) or 0
		src = translate("manual")
	end
	if type(r) ~= "number" or r < 1000 then return translate("not detected yet") end
	local m = 10
	local okm, mv = pcall(function() return uci:get("prio", "main", "shaper_margin") end)
	if okm and tonumber(mv) then m = math.floor(tonumber(mv)) end
	if m < 0 then m = 0 end
	if m > 50 then m = 50 end
	-- The estimate is the total gate; the margin only caps the bands below the
	-- top one. Both numbers are built here instead of as format specifiers
	-- inside the translatable string, because a translator who "fixes" %d%% to
	-- %d would make string.format raise and take the whole page down.
	local cap = math.floor(r * (100 - m) / 100)
	if auto == "1" and m > 0 then
		-- Numbers only: the total gate first, then the cap that applies to
		-- every band below the top one. No new msgids here, because a string
		-- without a compiled translation would show English on a Chinese page.
		return string.format("%.1f / %.1f Mbit/s", r / 1000, cap / 1000)
	end
	return string.format("%.1f Mbit/s (%s)", r / 1000, src)
end

o = s:option(DummyValue, "_learned", translate("Latency baseline"))
o.cfgvalue = function()
	local okA, auto = pcall(function() return uci:get("prio", "main", "auto_bandwidth") end)
	if auto ~= "1" then
		return translate("off -- a fixed rate is used")
	end
	local base = 0
	if fs.access("/var/run/luci-app-prio/rtt_base") then
		-- gsub returns (string, count); without the extra parentheses the
		-- count is passed to tonumber as a base and the page dies with
		-- "bad argument #2 to 'tonumber' (base out of range)".
		base = tonumber(((fs.readfile("/var/run/luci-app-prio/rtt_base") or ""):gsub("%s+", ""))) or 0
	end
	if base < 1 then
		return translate("not measured yet -- it is taken at a moment with no traffic")
	end
	return string.format("%d ms %s", base, translate("(measured while the line was idle)"))
end

o = s:option(DummyValue, "_queue")
o.title = translate("Priority queue")
o.cfgvalue = function()
	local st = ""
	-- A stale file must not claim a queue exists when the engine is down.
	if not qdisc_present() then
		return translate("engine not running")
	end
	if fs.access("/var/run/luci-app-prio/queue") then
		st = (fs.readfile("/var/run/luci-app-prio/queue") or ""):gsub("%s+$", "")
	end
	if st == "ok" then
		-- "ok" only means the detector saw the shaper dropping packets once.
		-- It must not claim a working queue when only the classifier is left.
		if not htb_present() then
			return translate("None -- only classification is installed, no queue")
		end
		return translate("Built -- the shaper is holding traffic back, so priority is in effect")
	end
	if st == "none" then
		-- "none" is written when traffic went through but never exceeded the
		-- shaping rate in that window. That is normal on a quiet line, but it
		-- is also what a rate set above the line's real capacity looks like,
		-- so it must not read as a verdict in either direction.
		if not htb_present() then
			return translate("None -- only classification is installed, no queue")
		end
		return translate("no local backlog in the last window -- traffic never exceeded " ..
			"the shaping rate. Normal on a quiet line; also what a rate set above the " ..
			"line's real capacity looks like.")
	end
	if st == "idle" then
		return translate("idle (no traffic in the last minute)")
	end
	return translate("unknown (no traffic seen yet)")
end

o = s:option(DummyValue, "_detail")
o.title = translate("Detail")
o.cfgvalue = function()
	if not fs.access("/var/run/luci-app-prio/status") then return "-" end
	local c = fs.readfile("/var/run/luci-app-prio/status") or ""
	if not c:find("started") then return "-" end
	local parts = {}
	if c:find("uplink:ok")       then parts[#parts+1] = translate("Uplink OK") end
	if c:find("uplink:fail")     then parts[#parts+1] = translate("Uplink FAILED") end
	if c:find("downlink:ok")     then parts[#parts+1] = translate("Downlink OK") end
	if c:find("downlink:inert")  then parts[#parts+1] = translate("Downlink only classified, no queue") end
	if c:find("downlink:fail")   then parts[#parts+1] = translate("Downlink FAILED") end
	if c:find("nft:ok")          then parts[#parts+1] = translate("Marking OK") end
	-- No rate here: this row summarises the engine's own status lines, while
	-- the live rate (including a probe in progress) has its own row above.
	-- Showing the value captured at the last rebuild made the two disagree.
	parts[#parts+1] = translate("Started")
	return table.concat(parts, " / ")
end

-- ============================================================
-- 全局设置
-- ============================================================
s = m:section(NamedSection, "main", "main", translate("Global Settings"))
s.anonymous = true
s.addremove = false

-- Only rendered when something is really wrong. A permanent "Attention: OK"
-- row is pure noise and reads like a malfunction.
local function attention()
	local okE, en = pcall(function() return uci:get("prio", "main", "enabled") end)
	if en ~= "1" then return nil end
	local okA, auto = pcall(function() return uci:get("prio", "main", "auto_bandwidth") end)
	local okR, r = pcall(function() return uci:get("prio", "main", "shaper_kbit") end)
	r = okR and tonumber(r) or 0
	if auto ~= "1" and (not r or r < 1000) then
		return translate("No downlink rate: without one there is no queue and priority does " ..
			"nothing. Enter a rate, or turn automatic learning back on.")
	end
	if not htb_present() then
		return translate("Only classification is installed, no queue yet -- priority is not " ..
			"in effect. Start a download so the rate can be learned, or set a fixed rate.")
	end
	-- The controller holds the rate when the probe target stops answering.
	-- Without this line a silent hold looks exactly like "priority is broken".
	if fs.access("/var/run/luci-app-prio/status") then
		local st = fs.readfile("/var/run/luci-app-prio/status") or ""
		if st:find("probe:down", 1, true) then
			return translate("The latency probe target is not answering, so the rate is " ..
				"held at its last value instead of being adjusted. Pick a reachable target.")
		end
	end
	return nil
end

local att = attention()
if att then
	o = s:option(DummyValue, "_warn", translate("Attention"))
	o.cfgvalue = function() return att end
end

o = s:option(Flag, "enabled", translate("Enable Device Priority"))
o.default = 0
o.rmempty = false
o.description = translate("Saving applies immediately. Turning it off restores the previous acceleration mode.")

o = s:option(Flag, "auto_bandwidth", translate("Measure the line automatically"))
o.default = 1
o.rmempty = false
o.description = translate("Capacity is measured, not guessed: the router downloads and " ..
	"uploads through its own unshaped path (using the built-in speedtest on a mainland " ..
	"node) and the shaper runs at that value minus the safety margin. The " ..
	"latency loop may only LOWER the rate afterwards, never raise it, because a " ..
	"round trip tells you that there is a queue but never how many bits fit.")

o = s:option(DummyValue, "_measured", translate("Last measurement"))
o.cfgvalue = function()
	local function num(v) return tonumber(v or "") or 0 end
	local ok1, dl = pcall(function() return uci:get("prio", "main", "measured_dl") end)
	local ok2, ul = pcall(function() return uci:get("prio", "main", "measured_ul") end)
	local ok3, at = pcall(function() return uci:get("prio", "main", "measured_at") end)
	dl, ul = num(ok1 and dl), num(ok2 and ul)
	local t0 = tonumber(ok3 and at or "") or 0

	local function ago(ts)
		local d = os.time() - ts
		-- A clock that stepped backwards must read as "just now", not as an
		-- empty parenthetical nor as a dangling separator.
		if d < 0 then d = 0 end
		if d < 120 then return translate("just now") end
		if d < 7200 then return string.format(translate("%d minutes ago"), math.floor(d / 60)) end
		return string.format(translate("%d hours ago"), math.floor(d / 3600))
	end

	-- Why the last attempt produced nothing. Without it a busy line, a held
	-- lock and a dead speedtest client all look like a button that does
	-- nothing at all. The reasons are written by measure() in the init script.
	local note = ""
	-- The measurement runs in the background now, so the page has to say that
	-- one is in progress instead of showing a stale number with no explanation.
	-- Existence alone is not enough: a run killed outright (SIGKILL, watchdog)
	-- leaves the marker behind and the page would claim "running" forever.
	local running = false
	local mst = fs.stat("/var/run/luci-app-prio/measuring")
	if mst and mst.mtime and (os.time() - mst.mtime) < 120 then running = true end
	if running then
		note = "  ·  " .. translate("measurement running now (about a minute)")
	elseif fs.access("/var/run/luci-app-prio/measure_err") then
		local ets, code, rest = (fs.readfile("/var/run/luci-app-prio/measure_err") or ""):match("^(%d+)%s+(%S+)%s*(.*)")
		ets = tonumber(ets) or 0
		local obs, thr = (rest or ""):match("^(%d+)%s+(%d+)")
		obs, thr = tonumber(obs), tonumber(thr)
		-- Literal translate() calls on purpose: a table of strings translated
		-- through a variable is invisible to the .po audit.
		local why
		if code == "busy" then
			why = translate("another measurement is still running")
		elseif code == "line-busy" then
			why = translate("the line was busy, so it was skipped")
			-- Numbers only, no new msgids: the English text above has a
			-- compiled translation, and a fresh one would render English on a
			-- Chinese page until the next i18n rebuild.
			if obs and thr and thr > 0 then
				why = string.format("%s · %.1f/%.1f Mbit/s", why, obs / 1000, thr / 1000)
			end
		elseif code == "no-data" then
			why = translate("nothing came back -- the line or the speedtest node was unreachable")
		elseif code == "no-iface" then
			why = translate("the WAN interface was missing")
		elseif code == "rejected" then
			why = translate("under half of the last one, so it was ignored")
		elseif code == "rejected-up" then
			why = translate("the upload measured under half of the last one, so it was ignored")
		elseif code == "disabled" then
			why = translate("the priority engine is switched off")
		end
		-- Only when it is newer than the number above: a stale note next to a
		-- fresh measurement would read like a contradiction.
		-- >= : a rejection can share the second with an accepted download, and
		-- the note must still show then.
		if why and ets >= t0 then
			note = "  ·  " .. string.format(translate("last attempt failed: %s (%s)"),
				why, ago(ets))
		end
	end

	if dl < 1 and ul < 1 then
		if note ~= "" then return translate("not measured yet") .. note end
		return translate("not measured yet")
	end
	local text = string.format("%.1f Mbit/s ↓  ·  %.1f Mbit/s ↑", dl / 1000, ul / 1000)
	local age = t0 > 0 and ago(t0) or ""
	if age ~= "" then text = text .. "  ·  " .. age end
	return text .. note
end

-- While a measurement is running the page reloads itself, so the user does not
-- have to guess when to hit F5. Nothing is added to an idle page: the row is
-- created only for a reload during a live measurement, or for the button's own
-- POST (CBI loads the model BEFORE it runs the write handler, so at that moment
-- the marker does not exist yet and only the submitted field proves it).
local refresh_now = false
local mst = fs.stat("/var/run/luci-app-prio/measuring")
if mst and mst.mtime and (os.time() - mst.mtime) < 120 then
	refresh_now = true
elseif http.getenv("REQUEST_METHOD") == "POST" and
       http.formvalue("cbid.prio.main._measure") ~= nil then
	refresh_now = true
end
if refresh_now then
	o = s:option(DummyValue, "_measuring_now", "")
	o.rawhtml = true
	o.cfgvalue = function()
		-- location.reload() is wrong here: this page is a POST result, and
		-- reloading it re-sends the form, which runs the button's write handler
		-- again and starts another 300 MB measurement. Navigate with a GET
		-- instead. The counter rides in the query string because a counter kept
		-- in the page is reset by the very reload it is supposed to limit.
		-- The row stays empty on screen: the row above already says what is
		-- happening, and an unlabelled row with no content costs no space.
		return "<script>(function(){var m=/[?&]_r=(\\d+)/.exec(location.search)," ..
			"n=m?+m[1]:0;if(n>=12)return;var q=location.search.replace(/[?&]_r=\\d+/,'')," ..
			"sep=q.indexOf('?')===0?'&':'?';" ..
			"setTimeout(function(){location.href=location.pathname+q+sep+'_r='+(n+1);},8000);" ..
			"})();</script>"
	end
end

-- The engine keeps a bounded, persistent log (/root/prio-diag.log) because the
-- failures worth debugging -- one band starved for hours, a rate pinned at the
-- floor overnight -- are invisible minutes later, and the syslog ring buffer
-- holds minutes. Anything it cannot do from the UI the user can read over ssh.
o = s:option(DummyValue, "_diag", translate("Diagnostic log (last lines)"))
o.rawhtml = true
o.cfgvalue = function()
	local f = "/root/prio-diag.log"
	local okv, off = pcall(function() return uci:get("prio", "main", "diag") end)
	local disabled = okv and off == "0"
	if not fs.access(f) then
		if disabled then
			return "<em>" .. translate("logging is switched off") .. "</em>"
		end
		return "<em>" .. translate("nothing logged yet") .. "</em>"
	end
	local txt = fs.readfile(f) or ""
	local lines = {}
	for l in txt:gmatch("[^\n]+") do lines[#lines + 1] = l end
	local from = math.max(1, #lines - 24)
	local out = {}
	for i = from, #lines do
		out[#out + 1] = (lines[i]:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
	end
	local head = disabled and ("<em>" .. translate("logging is switched off") .. "</em>") or ""
	return head .. "<pre style=\"margin:0;font-size:11px;line-height:1.35;white-space:pre-wrap\">" ..
		table.concat(out, "\n") .. "</pre>"
end
o.description = translate("Rate changes, measurement results and a snapshot of every " ..
	"band (bytes and drops) every few minutes, kept across reboots in " ..
	"/root/prio-diag.log (rotated at 128 kB). A band that is starved while the one " ..
	"above it is busy looks different from a line that is simply slow.")

o = s:option(Flag, "diag", translate("Write the diagnostic log"))
o.default = 1
o.rmempty = false
o.description = translate("Rate changes, measurements and a per-band snapshot every few " ..
	"minutes, kept in /root/prio-diag.log. Switching it off stops new lines; both the file " ..
	"and the rotated copy .1 are still pruned by age.")

o = s:option(ListValue, "diag_days", translate("Keep the log for"))
o.default = "7"
o.rmempty = false
o:value("3", translatef("%d days", 3))
o:value("7", translatef("%d days", 7))
o:value("14", translatef("%d days", 14))
o:value("0", translate("until the 128 kB cap (no age pruning)"))
o.description = translate("Lines older than this are dropped once a day, and the file is " ..
	"rotated at 128 kB either way. Set 0 to keep everything the size cap allows.")

o = s:option(Button, "_measure", translate("Measured capacity"))
o.inputtitle = translate("Measure now (up to a minute on a slow line)")
o.inputstyle = "reload"
o.description = translate("Uses the built-in speedtest client: it picks a mainland node " ..
	"(Guangzhou/Shenzhen Unicom here), runs several parallel streams and records what the " ..
	"line actually delivered. It costs real traffic -- roughly 300 MB on a fast line. " ..
	"Clicking returns immediately; the test itself runs in the background, so " ..
	"reload this page in a minute to see the result. " ..
	"With \"Measure the line automatically\" on and the line idle, a successful run " ..
	"replaces the remembered rate. Automatic re-measurements ignore a result under " ..
	"half of the previous one within a day (when that one was at least 5 Mbit/s), so a " ..
	"throttled test cannot pin the line; pressing this button overrides that check, " ..
	"because you have just looked at the connection.")
o.write = function()
	-- Detached on purpose: one run takes up to a minute and the old code made
	-- the browser wait for it, which a proxy or a slow phone turns into a
	-- timeout. The row above reports progress and the result.
	-- "force": a clicked measurement skips the under-half guard. That guard is
	-- there to keep an AUTOMATIC re-measure from pinning a throttled sample,
	-- but it also blocked the only way out when a long congestion had walked
	-- the rate close to the floor -- only a power cycle recovered it.
	require("luci.sys").call(
		"( /etc/init.d/prio measure force; /etc/init.d/prio apply 1 ) </dev/null >/dev/null 2>&1 &")
end

o = s:option(Flag, "downlink", translate("Shape Downlink (download)"))
o.default = 1
o.rmempty = false

o = s:option(Value, "shaper_kbit", translate("Downlink rate (kbit/s)"))
o.datatype = "uinteger"
o.placeholder = "15000"
-- Stays visible on purpose. Hiding it with o:depends made CBI drop the field
-- from the POST, and because rmempty is true the save then DELETED the user's
-- manual rate -- switching automatic measurement on once lost it for good.
o.description = translate("Only used when \"Measure the line automatically\" is off. " ..
	"0 leaves the downlink unshaped.")

o = s:option(Value, "shaper_margin", translate("Safety margin (%)"))
o.default = 10
o.datatype = "range(0,100)"
o.rmempty = false
o.description = translate("How far below the measured capacity to run, in percent. " ..
	"Only the measured value is reduced; a rate typed in by hand is used exactly as " ..
	"typed. Bigger means a deeper local queue (priority bites harder) but less peak " ..
	"throughput.")

o = s:option(Flag, "uplink", translate("Shape Uplink (upload)"))
o.default = 1
o.rmempty = false

o = s:option(Value, "uplink_kbit", translate("Uplink rate (kbit/s)"))
o.datatype = "uinteger"
o.placeholder = "0"
-- 1..999 would be rounded down to "automatic" by the backend, so the number
-- the user typed would look accepted and then quietly be ignored.
o.validate = function(self, value)
	if not value or value == "" then return value end
	-- Keep the uinteger check: overriding validate() replaces the datatype
	-- one, so "5000.7" would otherwise reach the backend, fail its digit test
	-- there and be read as 0 = automatic.
	-- Trim first: the backend treats any non-digit as "automatic", so a pasted
	-- "5000 " would silently turn shaping off while the page still said
	-- automatic.
	value = value:match("^%s*(.-)%s*$") or value
	if not value:match("^%d+$") then
		return nil, translate("Enter a whole number in kbit/s, or 0 for automatic.")
	end
	local n = tonumber(value)
	if n and n > 0 and n < 1000 then
		return nil, translate("Use 0 for automatic, or at least 1000 kbit/s: " ..
			"smaller values mean \"automatic\" to the backend and would be ignored.")
	end
	return value
end
o.description = translate("0 means automatic: the upload stays open until it has seen " ..
	"real upload traffic in three measuring windows (about a minute), then it starts " ..
	"shaping at what the line actually delivered and the same latency controller trims " ..
	"it. Enter a number to pin it instead. Leaving the upload unshaped lets a 4G modem " ..
	"buffer it internally, where this router cannot reorder anything.")

o = s:option(DummyValue, "_upshaper", translate("Uplink shaper"))
o.cfgvalue = function()
	-- Its own file: the controller rewrites the uplink rate on every change,
	-- and doing that by rewriting the shared status file raced with the other
	-- writers (a lost update could throw away "started"). Fall back to the old
	-- status line for an install upgraded from an older build.
	local v = nil
	if fs.access("/var/run/luci-app-prio/upshaper") then
		v = (fs.readfile("/var/run/luci-app-prio/upshaper") or ""):match("^([^\n]+)")
	end
	if not v and fs.access("/var/run/luci-app-prio/status") then
		v = (fs.readfile("/var/run/luci-app-prio/status") or ""):match("upshaper:([^\n]+)")
	end
	if not v then
		return translate("not reported yet")
	end
	if v == "auto" then
		return translate("automatic -- measuring the upload first")
	end
	if v == "pending" then
		return translate("not shaped -- automatic learning is off (turn on " ..
			"automatic bandwidth or enter a rate)")
	end
	local n = v:match("^(%d+)")
	n = n and tonumber(n) or 0
	if n < 1 then
		return translate("not reported yet")
	end
	return string.format("%.1f Mbit/s", n / 1000)
end

o = s:option(Value, "rtt_target", translate("Latency probe target"))
o.default = "223.5.5.5"
o.datatype = "host"
-- A private or loopback address measures the LAN, not the line: the round trip
-- is a fraction of a millisecond, the controller sees "no congestion" and walks
-- the rate up until the queue is back inside the modem, where priority does
-- nothing at all. Refuse it at the source instead of silently degrading.
o.validate = function(self, value)
	if not value or value == "" then return value end
	local a, b = value:match("^(%d+)%.(%d+)%.")
	a, b = tonumber(a), tonumber(b)
	if a == 10 or a == 127 or a == 0
	   or (a == 192 and b == 168)
	   or (a == 172 and b and b >= 16 and b <= 31)
	   or (a == 169 and b == 254) then
		return nil, translate("This is a local address: pinging it measures your " ..
			"own network, not the line. Use a public address.")
	end
	return value
end
o.description = translate("The shaper watches the round trip to this address: while it " ..
	"stays near the idle baseline the rate is left alone, when it climbs the rate comes " ..
	"down. Pick a stable public address near you; an unreachable one only produces a " ..
	"warning, because the shaper then has nothing to read.")

-- The picker shells out to traceroute, which is no longer a hard dependency
-- (the package name did not exist in the firmware feed and made apk refuse the
-- install). Show the button only when the binary is really there, instead of
-- offering one that silently does nothing.
local has_traceroute = false
do
	for _, p in ipairs({ "/usr/bin/traceroute", "/bin/traceroute",
	                     "/usr/sbin/traceroute", "/sbin/traceroute" }) do
		if fs.access(p) then has_traceroute = true break end
	end
end

if has_traceroute then
o = s:option(Button, "_pick_probe", translate("Pick the probe target"))
o.inputtitle = translate("Pick the closest hop automatically")
o.inputstyle = "reload"
o.description = translate("Runs one traceroute and uses the nearest hop that also answers a " ..
	"plain ping as the latency target. A hop inside your ISP shows your own access link's " ..
	"queue instead of the far end of the internet.")
o.write = function()
	require("luci.sys").call("/etc/init.d/prio pickprobe >/dev/null 2>&1")
end
else
o = s:option(DummyValue, "_pick_probe_off", translate("Pick the probe target"))
o.cfgvalue = function()
	return translate("automatic pick unavailable: traceroute is not installed")
end
o.description = translate("Install traceroute, or type the address of a nearby hop yourself.")
end

o = s:option(ListValue, "bands", translate("Number of Priority Bands"))
o.default = 3
o:value("3", translate("3 bands (recommended)"))
o:value("4", translate("4 bands"))
o:value("8", translate("8 bands"))
o.description = translate("Band 0 has the absolute highest priority. The remaining bands share bandwidth fairly.")

o = s:option(ListValue, "default_band", translate("Priority for devices not in the list"))
o.default = ""
o.rmempty = true
-- Empty must have its own entry. Without one, a ListValue renders the first
-- choice (band 0, the HIGHEST) while the stored value is empty (the LOWEST),
-- and the page then claims guests get top priority when they get the bottom.
o:value("", translatef("lowest band, band %d (recommended)", get_bands() - 1))
-- The lowest band is offered ONCE. Listing it twice (empty and "band N-1") gave
-- two spellings of the same setting, and the backend maps both to N-1 anyway.
for i = 0, get_bands() - 2 do
	o:value(tostring(i), translatef("Band %d", i))
end
-- A configuration that already holds the numeric top band (older versions, or
-- someone typing uci) must not render as "band 0" now that "band N-1" has no
-- choice of its own: map it onto the empty entry, which means the same thing.
o.cfgvalue = function(self, section)
	local ok, v = pcall(function() return uci:get("prio", "main", "default_band") end)
	if not ok or v == nil or v == "" then return "" end
	local n = tonumber(v)
	if n and n == get_bands() - 1 then return "" end
	return v
end
o.description = translate("Everything that is not in the device list still goes through " ..
	"the shaper; this is the band it gets. Empty means the lowest band, which is the " ..
	"safe choice: a new device cannot take bandwidth away from one you configured.")

o = s:option(Flag, "split_bands", translate("Separate upload priority"))
o.default = 0
o.rmempty = false
o.description = translate("Off: one priority for both directions, which is what the device " ..
	"table shows. On: every device gets a second column and can be top priority for " ..
	"upload while staying low for download (or the other way round).")

o = s:option(ListValue, "strict_bands", translate("Strict-priority levels"))
o.default = 1
o.rmempty = false
-- sch_ets serves the strict bands in index order and only then falls through
-- to DRR, so 2 strict bands with 3 bands really is three levels (0 > 1 > 2).
-- All bands strict is rejected: ETS needs one DRR band left over.
for n = 1, get_bands() - 1 do
	o:value(tostring(n), translatef("%d level(s)", n))
end
o.description = translate("How many bands are absolutely prioritised, taken from band 0 " ..
	"upwards. The rest share the leftover bandwidth fairly, with no order between them. " ..
	"With 3 bands choose 2 for a real three-level priority.")

-- Spell the resulting order out instead of making the reader derive it from
-- two numbers. Reads the SAVED configuration, like the other status rows, so
-- it always matches what the kernel is actually doing.
o = s:option(DummyValue, "_hierarchy", translate("Effective order"))
o.cfgvalue = function()
	local b = get_bands()
	local k = 1
	local okk, kv = pcall(function() return uci:get("prio", "main", "strict_bands") end)
	if okk and tonumber(kv) then k = math.floor(tonumber(kv)) end
	if k < 1 then k = 1 end
	if k > b - 1 then k = b - 1 end

	local function lbl(i) return translate("Band") .. " " .. i end
	local parts = {}
	for i = 0, k - 1 do parts[#parts + 1] = lbl(i) end
	local drr = b - k
	if drr == 1 then
		parts[#parts + 1] = lbl(k) .. translate(" (leftover only)")
	elseif drr > 1 then
		parts[#parts + 1] = lbl(k) .. "-" .. (b - 1) .. " " .. translate("share equally")
	end
	return table.concat(parts, " > ") .. "   ·   " ..
		translate("kernel parameter") .. ": strict " .. k .. "/" .. b
end

o = s:option(Flag, "fq_codel", translate("Fair queueing inside each band (fq_codel)"))
o.default = 1
o.rmempty = false
o.description = translate("Ticked: fq_codel queues every flow separately with a 3 ms target, " ..
	"so while a band is being served its flows see only a few milliseconds of queueing. That " ..
	"is per flow, not per host: a downloader with many connections still takes many shares. " ..
	"Cleared: a band is one bounded first-in-first-out queue (about 200 ms at 60 Mbit), so a " ..
	"device that keeps it full owns the band and the others wait behind it -- dog-eat-dog. " ..
	"Either way only the inside of a band changes: the ETS priority between bands is " ..
	"untouched, a busy higher strict band (band 0 by default) holds the lower bands back for " ..
	"as long as it stays busy, and the non-strict bands share whatever the strict ones leave.")

o = s:option(Flag, "lan_shaping", translate("Queue LAN traffic too"))
o.default = 0
o.rmempty = false
o.description = translate("Off: LAN-to-LAN transfers are never queued or limited. " ..
	"On: the LAN class is shaped at the wired link speed, so local traffic also forms a queue.")

o = s:option(Value, "lan_rate_kbit", translate("LAN rate (kbit/s)"))
o.datatype = "uinteger"
o.placeholder = "auto"
o.description = translate("Blank or 0 auto-detects the fastest wired port, falling back to 1000 Mbit/s.")

o = s:option(Value, "wan_iface", translate("WAN Interface"))
o.default = "eth2"
o.rmempty = false
o.description = translate("The 4G/5G or external uplink interface.")
o:value("eth2", "eth2")
local ok_dev, devs = pcall(function() return require("luci.sys").net.devices() end)
if ok_dev and type(devs) == "table" then
	for _, dv in ipairs(devs) do
		if type(dv) == "string" and dv ~= ""
		   and dv ~= "lo"
		   and not dv:match("^br%-")
		   and not dv:match("^ifb%-")
		   and dv ~= "eth2" then
			o:value(dv, dv)
		end
	end
end

o = s:option(ListValue, "lan_iface", translate("LAN Interface"))
o.default = "br-lan"
o.rmempty = false
o.description = translate("Where the downlink shaper is attached. Usually br-lan.")
o:value("br-lan", "br-lan")
if ok_dev and type(devs) == "table" then
	for _, dv in ipairs(devs) do
		if type(dv) == "string" and dv ~= ""
		   and dv ~= "lo"
		   and not dv:match("^ifb%-")
		   and dv ~= "br-lan" then
			o:value(dv, dv)
		end
	end
end

o = s:option(Flag, "auto_hnat_off", translate("Use software flow offloading"))
o.default = 1
o.rmempty = false
o.description = translate("Hardware HNAT bypasses the qdisc and would make priority useless. " ..
	"Software flow offloading keeps packets on the qdisc path.")

-- ============================================================
-- 设备优先级列表
-- ============================================================
local bands = get_bands()
local known = ip_index()

d = m:section(TypedSection, "device", translate("Device Priority List"))
d.anonymous = true
d.addremove = true
d.sortable = false
d.template = "cbi/tblsection"

o = d:option(Flag, "enabled", translate("Enable"))
o.default = 1
o.rmempty = false
o.width = "6%"

o = d:option(Value, "ip", translate("Device (IPv4)"))
o.datatype = "ip4addr"
o.rmempty = false
o.width = "40%"
o.description = translate("Pick a device or type its IPv4 address.")
for _, t in ipairs(read_static_hosts()) do
	o:value(t.ip, string.format("%s  (%s)", t.name, t.ip))
end
for _, t in ipairs(read_leases()) do
	if not (known and known[t.ip]) then
		o:value(t.ip, string.format("%s  (%s)", t.name, t.ip))
	end
end

o = d:option(ListValue, "band", translate("Priority Band"))
for i = 0, bands - 1 do
	o:value(tostring(i), translatef("Band %d", i))
end
o.default = 0
o.rmempty = false
o.width = "20%"

-- Upload and download are two independent queues, but one priority is what
-- people expect; the split is an advanced switch in the section above.
local ok_split, split = pcall(function() return uci:get("prio", "main", "split_bands") end)
if ok_split and split == "1" then
	o = d:option(ListValue, "band_up", translate("Priority Band (upload)"))
	for i = 0, bands - 1 do
		o:value(tostring(i), translatef("Band %d", i))
	end
	o.default = ""
	o.rmempty = true
	o.width = "20%"
	o.description = translate("Empty means the same band as download.")
end

-- ============================================================
-- 保存后立即应用（修 P0-2）
-- ============================================================
m.on_after_commit = function(self)
	local u = require("luci.model.uci").cursor()
	local en = u:get("prio", "main", "enabled")
	local call = require("luci.sys").call
	-- Fire and forget: a synchronous reload can block the page for several
	-- seconds and stack detector processes when the user retries.
	-- reload() already decides between start and stop from the committed UCI
	-- state, so it is the only thing that needs to run here. An explicit stop
	-- from this hook used to fire while the commit was still in flight, which
	-- is how the engine could end up stopped with the switch visibly on.
	-- Pass the intended state instead of letting the script re-read UCI: this
	-- hook can run before the commit is visible, and the engine used to act on
	-- the previous switch position.
	if en == "1" then
		call("/etc/init.d/prio enable >/dev/null 2>&1")
	else
		call("/etc/init.d/prio disable >/dev/null 2>&1")
	end
	call("/etc/init.d/prio apply " .. (en == "1" and "1" or "0") .. " >/dev/null 2>&1 &")
end

-- ============================================================
-- 说明
-- ============================================================
s = m:section(SimpleSection)
s.anonymous = true

o = s:option(DummyValue, "_help")
o.title = translate("How it works")
o.cfgvalue = function()
	return translate("Band 0 is strictly prioritised; the other bands share bandwidth via DRR. " ..
		"Traffic is marked before NAT, so the classification applies to forwarded traffic. " ..
		"A shaper on the downlink path keeps a queue so the scheduler has something to reorder. " ..
		"Download and upload are two separate queues: download is matched by the destination " ..
		"address, upload by the source, so the two band columns are independent.")
end

return m
