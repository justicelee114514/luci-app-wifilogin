-- Copyright (C) 2026 wifilogin contributors
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- /usr/lib/lua/luci/controller/wifilogin.lua
module("luci.controller.wifilogin", package.seeall)

local fs = require "nixio.fs"

function index()
	if not fs.access("/etc/config/wifilogin") then
		return
	end

	entry({"admin", "services", "wifilogin"},
		cbi("wifilogin/settings"),
		_("Portal 自动登录"), 60).dependent = false

	entry({"admin", "services", "wifilogin", "action"},
		call("action")).leaf = true
end

function action()
	local act = luci.http.formvalue("act") or ""
	local cmd

	if act == "login" then
		cmd = "/usr/bin/wifilogin.sh force"
	elseif act == "status" then
		cmd = "/usr/bin/wifilogin.sh status"
	elseif act == "testportal" then
		cmd = "/usr/bin/wifilogin.sh testportal"
	elseif act == "diag" then
		cmd = "/usr/bin/wifilogin.sh diag"
	else
		luci.http.redirect(luci.dispatcher.build_url("admin/services/wifilogin"))
		return
	end

	fs.mkdirr("/tmp/wifilogin")

	local out = luci.sys.exec(cmd .. " 2>&1") or ""

	local f = io.open("/tmp/wifilogin/manual.log", "w")
	if f then
		f:write(os.date("%Y-%m-%d %H:%M:%S"), "  ", cmd, "\n")
		f:write(out)
		f:close()
	end

	luci.http.redirect(luci.dispatcher.build_url("admin/services/wifilogin"))
end
