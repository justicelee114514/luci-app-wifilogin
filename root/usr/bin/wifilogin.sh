#!/bin/sh
# Copyright (C) 2026 wifilogin contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
# /usr/bin/wifilogin.sh
#
# 校园宽带 Portal(OpenAS/Dr.COM) 自动登录
# 用法: wifilogin.sh check    # 单次检测+登录
#       wifilogin.sh daemon   # 常驻循环(procd 托管)
#       wifilogin.sh force    # 强制登录一次(LuCI 手动触发)
#       wifilogin.sh testportal # 只探测登录页(LuCI「测试网关」按钮)
#       wifilogin.sh diag     # 收集网络诊断(LuCI「诊断」按钮)
#       wifilogin.sh status   # 查看状态

. /lib/functions.sh

STATE_DIR=/tmp/wifilogin
FAILFILE="$STATE_DIR/fails"
COOKIE="$STATE_DIR/cookies.txt"

mkdir -p "$STATE_DIR"

VERBOSE=0

log() {
	logger -t wifilogin "$*"
	[ "$VERBOSE" = "1" ] && echo "[$(date '+%H:%M:%S')] $*"
	return 0
}

note() {
	[ "$VERBOSE" = "1" ] && echo "[$(date '+%H:%M:%S')] $*"
	return 0
}

cfg() {
	config_load wifilogin
	config_get_bool ENABLED  main enabled   1
	config_get      PORTAL   main portal    ""
	config_get      ACNAME   main acname    ""
	config_get_bool DISCOVER main discover  1
	config_get      CHECKURL main check_url "http://connect.rom.miui.com/generate_204"
	config_get      CHECKURL2 main check_url2 "http://www.baidu.com"
	config_get_bool MACSAVE  main macsave   0
	config_get      MACAGE   main macage    6
	config_get      INTERVAL main interval  60
	config_get      ACTIVE   main active    ""

	USERNAME=""
	PASSWORD=""

	# 1) 页面选中的账号(config account 的段名)
	if [ -n "$ACTIVE" ]; then
		config_get USERNAME "$ACTIVE" username ""
		config_get PASSWORD "$ACTIVE" password ""
	fi

	# 2) 老配置：账号直接写在 main 里
	if [ -z "$USERNAME" ]; then
		config_get USERNAME main username ""
		config_get PASSWORD main password ""
	fi

	# 3) 还没有则用第一条 account
	if [ -z "$USERNAME" ]; then
		config_foreach _first_account account
	fi
}

_first_account() {
	[ -n "$USERNAME" ] && return 0
	config_get USERNAME "$1" username ""
	config_get PASSWORD "$1" password ""
	ACTIVE="$1"
}

# ---------- 在线判断 ----------
is_online() {
	local code

	code=$(curl -s -o "$STATE_DIR/probe" -w '%{http_code}' \
		--max-time 8 "$CHECKURL" 2>/dev/null)
	[ "$code" = "204" ] && return 0

	# 204 探测被劫持/不可用时，用普通网页判断是否被 Portal 拦截
	code=$(curl -s -o "$STATE_DIR/probe2" -w '%{http_code}' \
		--max-time 8 "$CHECKURL2" 2>/dev/null)
	[ "$code" = "200" ] || return 1
	# 返回 200 但内容是 Portal 劫持页 → 仍然算未认证
	grep -qiE "bpssUSERNAME|showLogin\.do|211\.138\.1\.146" "$STATE_DIR/probe2" && return 1
	return 0
}

# ---------- 失败计数 ----------
get_fails() { cat "$FAILFILE" 2>/dev/null || echo 0; }
set_fails() { echo "$1" > "$FAILFILE"; }

# 下一次 run_once 之后该睡多久（秒）；do_login 按失败类型写，daemon 读完即清
set_backoff() { echo "$1" > "$STATE_DIR/backoff"; }
take_backoff() {
	local b
	b=$(cat "$STATE_DIR/backoff" 2>/dev/null)
	rm -f "$STATE_DIR/backoff"
	echo "${b:-300}"
}

# 从 LOGIN_GET 里抠出主机名，给 ping 用
portal_host() {
	local h="${LOGIN_GET#http://}"
	h="${h#https://}"
	h="${h%%/*}"
	h="${h%%:*}"
	echo "$h"
}

# 一次性收集网络诊断信息，页面上的「诊断」按钮和 SSH 都用得上
diag() {
	local out="$STATE_DIR/diag.txt"

	portal_urls

	{
		echo "### 时间"
		date
		echo
		echo "### 配置"
		echo "portal  = $PORTAL"
		echo "登录页  = $LOGIN_GET"
		echo "提交页  = $LOGIN_POST"
		echo "enabled = $ENABLED"
		echo "默认路由: $(if has_default_route; then echo 有; else echo 没有; fi)"
		echo
		echo "### 接口地址"
		if command -v ip >/dev/null 2>&1; then
			ip -4 addr show 2>&1
		else
			ifconfig -a 2>&1
		fi
		echo
		echo "### 路由"
		if command -v ip >/dev/null 2>&1; then
			ip route show 2>&1
			echo "--- 全部表 ---"
			ip route show table all 2>&1 | head -n 40
		else
			route -n 2>&1
		fi
		echo
		if [ -n "$LOGIN_GET" ]; then
			echo "### ping 网关主机 ($(portal_host))"
			ping -c 2 -W 2 "$(portal_host)" 2>&1
			echo
			echo "### curl 登录页 (-v)"
			curl -v --max-time 10 "$LOGIN_GET" -o /dev/null 2>&1 | tail -n 20
		else
			echo "### 没有可用的 Portal 地址（自动探测失败，且未配置网关地址）"
		fi
		echo
		echo "### curl 204 探测"
		curl -sS -o /dev/null -w 'http_code=%{http_code} time=%{time_total}\n' \
			--max-time 8 "$CHECKURL" 2>&1
		echo
		echo "### 最近日志"
		logread -e wifilogin 2>&1 | tail -n 15
	} > "$out" 2>&1

	cat "$out"
}

# ---------- 认证地址 ----------
# 默认路由所在的接口：Portal 认的是这个口的 IP/MAC，不是 br-lan 的
iface_of_default() {
	local d
	if command -v ip >/dev/null 2>&1; then
		d=$(ip route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
	fi
	[ -n "$d" ] || d=$(route -n 2>/dev/null | awk '$1=="0.0.0.0" {print $8; exit}')
	echo "$d"
}

iface_ip() {
	[ -n "$1" ] || return 0
	ip -4 addr show dev "$1" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n1
}

iface_mac() {
	local m
	[ -n "$1" ] || return 0
	m=$(cat "/sys/class/net/$1/address" 2>/dev/null)
	echo "$m" | tr 'A-F' 'a-f' | tr ':' '-'
}

# 未认证时 AC 会把任意 HTTP 请求 302 到带 wlanuserip/user-mac 的登录页。
# 抓这个 Location 最可靠：用户的 IP、MAC、AC 名一次全齐，不用自己拼
discovered_portal_url() {
	local out loc u
	for u in "$CHECKURL" "$CHECKURL2"; do
		out=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 8 "$u" 2>/dev/null)
		loc=${out#* }
		case "$loc" in
			*showLogin.do*) echo "$loc"; return 0 ;;
		esac
	done
	return 1
}

# ---------- 登录 ----------
# 把 PORTAL 归一化成两个完整地址：
#   LOGIN_GET  —— 登录页(GET)。默认先问 AC 要（最可靠）；探测失败才退回配置
#   LOGIN_POST —— 提交地址(POST)，由登录页地址换掉尾部 showLogin.do
#
# 取址优先级：
#   1) AC 302 重定向给的完整地址（带 wlanuserip / wlanacname / user-mac）
#   2) 页面里配的完整地址（含 ? 或 showLogin.do）—— 探测失败时的后备
#   3) 页面里配的主机 + 默认路由接口的 IP/MAC 自己拼
portal_urls() {
	local p="$PORTAL" dev lip mac q disc

	p="${p%/}"
	if [ -n "$p" ]; then
		case "$p" in
			http://*|https://*) : ;;
			*) p="http://$p" ;;
		esac
	fi

	LOGIN_GET=""
	LOGIN_POST=""

	# 1) 先探 AC：未认证时它会把任意 HTTP 请求 302 到带参数的登录页
	if [ "$DISCOVER" = "1" ]; then
		disc=$(discovered_portal_url)
		if [ -n "$disc" ]; then
			LOGIN_GET="$disc"
			note "认证地址来自 AC 重定向"
		fi
	fi

	# 2)/3) 探测不到才用配置
	if [ -z "$LOGIN_GET" ] && [ -n "$p" ]; then
		case "$p" in
			*\?*|*showLogin.do*)
				# 用户填了带参数的完整地址，原样使用
				LOGIN_GET="$p"
				;;
			*)
				LOGIN_GET="$p/showLogin.do"
				# 自己拼，参数取自默认路由所在接口
				dev=$(iface_of_default)
				lip=$(iface_ip "$dev")
				mac=$(iface_mac "$dev")
				q=""
				[ -n "$lip" ] && q="$q&wlanuserip=$lip"
				[ -n "$ACNAME" ] && q="$q&wlanacname=$ACNAME"
				[ -n "$mac" ] && q="$q&user-mac=$mac"
				[ -n "$q" ] && LOGIN_GET="$LOGIN_GET?${q#&}"
				;;
		esac
	fi

	[ -z "$LOGIN_GET" ] && return 0

	LOGIN_POST="${LOGIN_GET%%\?*}"
	case "$LOGIN_POST" in
		*showLogin.do) LOGIN_POST="${LOGIN_POST%showLogin.do}login.do" ;;
		*) LOGIN_POST="$LOGIN_POST/login.do" ;;
	esac
}

# 返回: 0 成功  1 密码错  2 需验证码/被锁  3 网络/其他错误
do_login() {
	local page code csrf resp msg fails penalty

	portal_urls

	if [ -z "$LOGIN_GET" ]; then
		log "没有可用的 Portal 地址：自动探测失败，页面里也没填网关地址"
		note "结果: 没有可用的 Portal 地址"
		return 3
	fi

	note "认证地址: $LOGIN_GET"

	rm -f "$COOKIE"
	page="$STATE_DIR/login.html"

	code=$(curl -sS -o "$page" -c "$COOKIE" -w '%{http_code}' \
		--max-time 10 "$LOGIN_GET" 2>"$STATE_DIR/curl.err")
	[ "$code" = "200" ] || {
		log "GET $LOGIN_GET 失败 (HTTP ${code:-000}): $(head -n 2 "$STATE_DIR/curl.err" 2>/dev/null | tr '\n' ' ')"
		note "curl: $(head -n 2 "$STATE_DIR/curl.err" 2>/dev/null | tr '\n' ' ')"
		return 3
	}

	csrf=$(sed -n "s/.*name='CSRFHW' value='\([^']*\)'.*/\1/p" "$page" | head -n1)
	[ -n "$csrf" ] || log "警告: 页面未找到 CSRFHW，继续尝试"

	set -- \
		--data-urlencode "showVerify=false" \
		--data-urlencode "loginType=1" \
		--data-urlencode "bpssUSERNAME=$USERNAME" \
		--data-urlencode "bpssBUSPWD=$PASSWORD" \
		--data-urlencode "bpssVERIFY=" \
		--data-urlencode "CSRFHW=$csrf"

	if [ "$MACSAVE" = "1" ]; then
		set -- "$@" \
			--data-urlencode "macautologin=macsave" \
			--data-urlencode "macAge=$MACAGE"
	fi

	resp=$(curl -sS -b "$COOKIE" -c "$COOKIE" --max-time 15 \
		"$@" "$LOGIN_POST" 2>"$STATE_DIR/curl.err")
	echo "$resp" > "$STATE_DIR/last_response.html"

	# 认证结果以"能不能上网"为准，不依赖返回页文案
	if is_online; then
		set_fails 0
		rm -f "$STATE_DIR/backoff"
		log "登录成功 (账号 $USERNAME)"
		return 0
	fi

	msg=$(printf '%s' "$resp" | sed -n 's/.*alert("\([^"]*\)").*/\1/p' | head -n1)
	[ -n "$msg" ] || msg="(无法解析返回内容)"

	case "$msg" in
	*锁定*)
		set_fails 0
		log "账号被锁定: $msg —— 停止尝试 15 分钟"
		set_backoff 900
		return 2
		;;
	*验证码*)
		log "服务端要求验证码: $msg —— 本脚本不处理验证码，退避 5 分钟"
		set_backoff 300
		return 2
		;;
	*用户名或密码*)
		fails=$(get_fails)
		fails=$((fails + 1))
		set_fails "$fails"
		log "登录失败($fails/3): $msg"
		if [ "$fails" -ge 3 ]; then
			log "连续失败 $fails 次，为避免账号被锁，暂停 30 分钟"
			set_backoff 1800
			return 2
		fi
		return 1
		;;
	*)
		log "未知返回: $msg"
		[ -s "$STATE_DIR/curl.err" ] && log "curl: $(head -n 2 "$STATE_DIR/curl.err" | tr '\n' ' ')"
		return 3
		;;
	esac
}

# 路由器有没有默认路由（没有的话连 Portal 都够不着）
has_default_route() {
	if command -v ip >/dev/null 2>&1; then
		ip route show 2>/dev/null | grep -q '^default'
	else
		route -n 2>/dev/null | grep -q '^0\.0\.0\.0'
	fi
}

# ---------- 单次执行 ----------
run_once() {
	if is_online; then
		[ "$(get_fails)" != "0" ] && log "当前已在线"
		note "已在线，无需登录"
		set_fails 0
		return 0
	fi

	if ! has_default_route; then
		log "没有默认路由(ip route 里没有 default)，连 Portal 都够不着——检查 WISP/上游 WiFi 是否连上、接口有没有拿到网关"
		note "结果: 没有默认路由，检查上游连接"
		return 3
	fi

	if [ -z "$USERNAME" ]; then
		log "未配置宽带账号，请在 LuCI 页面里添加"
		note "结果: 未配置账号"
		return 3
	fi

	log "检测到未认证，开始登录(账号 $USERNAME)..."
	do_login
	local rc=$?
	case $rc in
	0) note "结果: 登录成功" ;;
	1) note "结果: 账号或密码错误" ;;
	2) note "结果: 需要验证码或账号被锁定，已退避" ;;
	*) note "结果: 网络异常或未知错误" ;;
	esac
	return $rc
}

case "$1" in
status)
	cfg
	if is_online; then
		echo "online"
	else
		echo "offline (fails=$(get_fails))"
	fi
	;;
testportal)
	# LuCI 页面「测试网关」按钮：只探测登录页能不能打开，不提交账号
	cfg
	portal_urls
	if [ -z "$LOGIN_GET" ]; then
		echo "没有可用的 Portal 地址：自动探测失败，页面里也没填网关地址"
		exit 2
	fi
	echo "登录页: $LOGIN_GET"
	echo "提交页: $LOGIN_POST"

	code=$(curl -s -o "$STATE_DIR/portal_test.html" -w '%{http_code}' \
		--max-time 10 "$LOGIN_GET" 2>/dev/null)
	echo "HTTP  : ${code:-000}"

	if [ -f "$STATE_DIR/portal_test.html" ]; then
		if grep -q "bpssUSERNAME" "$STATE_DIR/portal_test.html" 2>/dev/null; then
			echo "页面  : 正常，含登录表单"
		else
			echo "页面  : 不含登录表单，开头内容:"
			head -c 120 "$STATE_DIR/portal_test.html" 2>/dev/null | tr -d '\r'
			echo
		fi
	fi
	;;
diag)
	# LuCI 页面「诊断」按钮：收集接口/路由/ping/curl -v，不碰账号
	cfg
	diag
	;;
daemon)
	cfg
	[ "$ENABLED" = "1" ] || { log "已禁用，退出"; exit 0; }

	# 等待网络就绪
	sleep 5
	while :; do
		run_once
		case $? in
		0) sleep "$INTERVAL" ;;
		1) sleep "$INTERVAL" ;;
		2) sleep "$(take_backoff)" ;;   # 验证码 / 锁定 / 连败，时长由 do_login 决定
		3) sleep 600 ;;   # 没配账号，慢点重试，少刷日志
		*) sleep 120 ;;
		esac
	done
	;;
check|"")
	cfg
	[ "$ENABLED" = "1" ] || exit 0
	run_once
	;;
force)
	# LuCI 页面手动触发：忽略 enabled，并把过程输出到 stdout
	VERBOSE=1
	cfg
	run_once
	;;
*)
	echo "用法: $0 {check|force|testportal|diag|daemon|status}"
	exit 1
	;;
esac
