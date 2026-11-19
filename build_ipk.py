#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Copyright (C) 2026 wifilogin contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
"""
本地构建 wifilogin ipk（无需 OpenWrt SDK）。
用法: python build_ipk.py [版本号]
产物: wifilogin_<版本>_all.ipk   (OpenWrt 的 ipk = 外层 tar.gz)
"""
import io, os, sys, tarfile, time

ROOT = os.path.dirname(os.path.abspath(__file__))
VERSION = sys.argv[1] if len(sys.argv) > 1 else "0.1.0"

FILES = [
    ("root/usr/bin/wifilogin.sh",          "usr/bin/wifilogin.sh",                  0o755),
    ("root/etc/init.d/wifilogin",          "etc/init.d/wifilogin",                  0o755),
    ("root/etc/hotplug.d/iface/90-wifilogin", "etc/hotplug.d/iface/90-wifilogin",   0o755),
    ("root/etc/config/wifilogin",          "etc/config/wifilogin",                  0o600),
    ("luasrc/controller/wifilogin.lua",
     "usr/lib/lua/luci/controller/wifilogin.lua",                                  0o644),
    ("luasrc/model/cbi/wifilogin/settings.lua",
     "usr/lib/lua/luci/model/cbi/wifilogin/settings.lua",                           0o644),
    ("luasrc/view/wifilogin/status.htm",
     "usr/lib/lua/luci/view/wifilogin/status.htm",                                  0o644),
]

CONTROL = """Package: wifilogin
Version: {ver}
Section: net
Architecture: all
Maintainer: wifilogin contributors
License: AGPL-3.0-or-later
Depends: luci-base, luci-compat
Description: Campus portal (OpenAS/Dr.COM) auto login for OpenWrt.
 Detects captive portal via a 204 probe, performs /showLogin.do + /login.do
 authentication, and backs off on captcha/lockout. Adds a LuCI page under
 Services where the account/password can be stored and a login can be
 triggered manually. Requires the 'curl' package.
"""

POSTINST = """#!/bin/sh
chmod 755 /usr/bin/wifilogin.sh /etc/init.d/wifilogin /etc/hotplug.d/iface/90-wifilogin 2>/dev/null
chmod 600 /etc/config/wifilogin 2>/dev/null
# 升级时若本地改过配置，opkg 会把包内默认值另存为 /etc/config/wifilogin-opkg，清掉免得混淆
rm -f /etc/config/wifilogin-opkg
# 老配置万一没有 main 段，补一个，页面才不会空白
if ! uci -q get wifilogin.main >/dev/null 2>&1; then
	touch /etc/config/wifilogin 2>/dev/null
	uci set wifilogin.main=wifilogin 2>/dev/null
	uci commit wifilogin 2>/dev/null
fi
# 让新菜单立刻出现在 LuCI 中
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null
exit 0
"""


def add(tar, name, data, mode):
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    ti.mode = mode
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mtime = int(time.time())
    if name.endswith("/"):
        # 必须是真正的目录条目(typeflag='5')，opkg 只认这个
        ti.type = tarfile.DIRTYPE
        ti.size = 0
        tar.addfile(ti)
        return
    tar.addfile(ti, io.BytesIO(data))


def tar_bytes(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as t:
        for name, data, mode in entries:
            add(t, name, data, mode)
    return buf.getvalue()


def main():
    data_entries = []
    seen_dirs = set()
    for src, dst, mode in FILES:
        path = os.path.join(ROOT, src)
        # 先补齐所有父目录条目 —— busybox tar 不会自动建父目录，
        # 缺了就会报 "wfopen: ...: No such file or directory"
        parts = dst.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            d = "/".join(parts[:i]) + "/"
            if d not in seen_dirs:
                seen_dirs.add(d)
                data_entries.append(("./" + d, b"", 0o755))
        with open(path, "rb") as f:
            data_entries.append(("./" + dst, f.read(), mode))

    ctl_entries = [
        ("./control",   CONTROL.format(ver=VERSION).encode(), 0o644),
        ("./conffiles", b"/etc/config/wifilogin\n",            0o644),
        ("./postinst",  POSTINST.encode(),                     0o755),
    ]

    outer = [
        ("./debian-binary", b"2.0\n",                 0o644),
        ("./control.tar.gz", tar_bytes(ctl_entries),  0o644),
        ("./data.tar.gz",    tar_bytes(data_entries), 0o644),
    ]

    out = os.path.join(ROOT, "wifilogin_%s_all.ipk" % VERSION)
    with open(out, "wb") as f:
        f.write(tar_bytes(outer))
    print("built:", out, os.path.getsize(out), "bytes")
    print("files:", len(data_entries))


if __name__ == "__main__":
    main()
