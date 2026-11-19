-- Copyright (C) 2026 wifilogin contributors
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- /usr/lib/lua/luci/model/cbi/wifilogin/settings.lua
local m, s, o
local uci = require("luci.model.uci").cursor()

m = Map("wifilogin", translate("Portal 自动登录"),
	translate("校园网 Portal(OpenAS) 自动认证。宽带账号可以添加多条，" ..
		"用「当前使用的账号」切换，保存后点下方「立即登录」立刻验证一次。"))

-- ① 服务设置
s = m:section(NamedSection, "main", "wifilogin", translate("服务设置"))
s.addremove = false

o = s:option(Flag, "enabled", translate("启用自动登录"))
o.rmempty = false

o = s:option(ListValue, "active", translate("当前使用的账号"))
o.default = ""
o:value("", translate("（自动：第一条）"))
uci:foreach("wifilogin", "account", function(sec)
	local name = sec[".name"]
	local label = sec.label

	if not label or label == "" then
		label = sec.username
	end
	if not label or label == "" then
		label = name
	end

	o:value(name, string.format("%s (%s)", label, name))
end)
o.description = translate("下面的账号列表里可能有多个；这里选哪个就用哪个登录。")

o = s:option(Flag, "discover", translate("自动探测 AC 下发的登录地址"))
o.default = "1"
o.rmempty = false
o.description = translate("推荐开启。未认证时 AC 会把任意请求 302 到带 wlanuserip / wlanacname / user-mac " ..
	"的登录页，直接抓这个地址最准，不用自己拼。关掉后只用下面填的地址。")

o = s:option(Value, "portal", translate("网关（Portal）地址"))
o.placeholder = "10.1.2.3:8080"
o.description = translate("探测失败时的后备地址。填 IP:端口 就行，脚本会自己补 http:// 和 /showLogin.do；" ..
	"也可以直接粘贴浏览器里那串完整的 showLogin.do?... 链接，参数会原样带上。" ..
	"留空则只靠 AC 探测；探测不到时需要再填「AC 名称」，脚本会用默认路由接口的 IP/MAC 自己拼。")

o = s:option(Value, "acname", translate("AC 名称（可选）"))
o.placeholder = "0015.0000.000.00"
o.description = translate("一般留空即可：脚本会从 302 跳转里拿到。" ..
	"只有抓不到跳转、又必须自己拼认证地址时才需要手填；" ..
	"这个值就是浏览器地址栏里 wlanacname= 后面那段。")

o = s:option(Value, "interval", translate("在线检测间隔(秒)"))
o.datatype = "uinteger"
o.placeholder = "60"

o = s:option(Flag, "macsave", translate("申请免密登录"))
o.description = translate("勾选后会在 Portal 侧做 MAC 绑定，有效期内免认证。")

o = s:option(ListValue, "macage", translate("免密有效期"))
o:value("1", translate("1 个月"))
o:value("6", translate("6 个月"))
o:value("12", translate("1 年"))
o:depends("macsave", "1")

-- ② 账号列表（可增删）
s = m:section(TypedSection, "account", translate("宽带账号"),
	translate("点「添加」新增一条，填备注 / 账号 / 密码；行尾的「删除」可以移除。" ..
		"保存后重新打开本页，新账号才会出现在上面的下拉框里。"))
s.template = "cbi/tblsection"
s.anonymous = true
s.addremove = true

o = s:option(Value, "label", translate("备注"))
o.placeholder = translate("如：我的移动")

o = s:option(Value, "username", translate("宽带账号"))
o.placeholder = "138xxxxxxxx"
o.rmempty = false

o = s:option(Value, "password", translate("宽带密码"))
o.password = true
o.rmempty = false

-- ③ 状态 / 手动操作
m:section(SimpleSection).template = "wifilogin/status"

function m.on_after_commit(self)
	luci.sys.call("/etc/init.d/wifilogin reload >/dev/null 2>&1")
end

return m
