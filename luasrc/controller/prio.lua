-- Copyright 2026 congge
--
-- The menu entry is declared in /usr/share/luci/menu.d/prio.json, which is
-- sufficient on LuCI >= 21.02. Registering it here as well would duplicate the
-- node (the two dispatchers disagree about ACL and ordering), so this
-- controller deliberately registers nothing. It exists only so that older
-- installations that still reference luci.controller.prio do not error out.
module("luci.controller.prio", package.seeall)

function index()
end
