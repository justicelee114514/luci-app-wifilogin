# OpenWrt 校园网 Portal 自动登录（OpenAS / Dr.COM）

为方便多设备在宿舍联网，于是给之前买的路由器写了这个脚本。

脚本的思路很简单：让路由器自己去认证。WISP/NAT 模式下 AC 看到的是路由器的 IP 和 MAC，
路由器登一次，下游所有设备就都通了。

只对 OpenAS / 城市热点 Dr.COM 这一类（登录页是 `showLogin.do?...`、表单字段叫 `bpssUSERNAME` 的那种）。别家的 Portal 字段不一定一样，直接套用是不行的。

不想折腾源码的，[Releases](https://github.com/justicelee114514/luci-app-wifilogin/releases) 里有打好的 ipk。

## 仓库里有什么

| 文件 | 装到哪 | 说明 |
|---|---|---|
| `root/usr/bin/wifilogin.sh` | `/usr/bin/wifilogin.sh` | 主脚本，check / force / testportal / diag / daemon / status |
| `root/etc/init.d/wifilogin` | `/etc/init.d/wifilogin` | procd 服务 |
| `root/etc/config/wifilogin` | `/etc/config/wifilogin` | UCI 配置 |
| `root/etc/hotplug.d/iface/90-wifilogin` | `/etc/hotplug.d/iface/90-wifilogin` | 接口 up 时触发一次登录 |
| `luasrc/controller/wifilogin.lua` | `/usr/lib/lua/luci/controller/wifilogin.lua` | 注册菜单 |
| `luasrc/model/cbi/wifilogin/settings.lua` | `/usr/lib/lua/luci/model/cbi/wifilogin/settings.lua` | 页面表单 |
| `luasrc/view/wifilogin/status.htm` | `/usr/lib/lua/luci/view/wifilogin/status.htm` | 状态区和那几个按钮 |
| `build_ipk.py` | —— | 打包脚本，不需要 OpenWrt SDK |

仓库里不放大文件，打好的 ipk 都在 [Releases](https://github.com/justicelee114514/luci-app-wifilogin/releases) 里。

## 安装软件包

### 装现成的 ipk（推荐）

到 [Releases](https://github.com/justicelee114514/luci-app-wifilogin/releases) 下最新的
`wifilogin_all.ipk`（带版本号的那份内容一样），不用自己编译。

路由器自己能上网的话，直接在路由器上下最快：

```sh
opkg update && opkg install curl ca-bundle

cd /tmp
wget -O wifilogin.ipk \
  https://github.com/justicelee114514/luci-app-wifilogin/releases/latest/download/wifilogin_all.ipk
opkg install ./wifilogin.ipk
```

`latest/download` 后面的文件名得和 Release 里的资产名一字不差；所以发版时记得额外传一份
不带版本号的 `wifilogin_all.ipk`（发版那节写了）。

下不下来的话，电脑下好再传上去（`-O` 别省）：

```sh
scp -O wifilogin_all.ipk root@192.168.1.1:/tmp/
opkg install /tmp/wifilogin_all.ipk
```

`-O` 不是可选项：OpenSSH 9 以后默认走 SFTP，路由器的 dropbear 只认老式 SCP，不加会卡在那儿不动。

Release 页面里附了 sha256，想核对就 `sha256sum wifilogin.ipk` 对一眼。

装完打开 `服务 → Portal 自动登录`，填账号密码，保存，再点「立即登录」看结果。

菜单没冒出来就清一下 LuCI 缓存，然后刷新：

```sh
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache
```

升级时多半会看到这么一段：

```
* resolve_conffiles: Existing conffile /etc/config/wifilogin is different
  from the conffile in the new package. The new conffile will be placed at /etc/config/wifilogin-opkg.
```

不用紧张，这不是装失败。opkg 发现你改过 `/etc/config/wifilogin`，就把包里的默认值另存到
`/etc/config/wifilogin-opkg`，你在页面上存的账号密码一个没动。确认下版本就行：

```sh
opkg list-installed | grep wifilogin
```

那个 `-opkg` 文件新的 postinst 会自己删，老版本可以手动 `rm -f /etc/config/wifilogin-opkg`。

页面是老式的 Lua CBI 写的，新版 LuCI 得靠 `luci-compat` 才能渲染（依赖里声明了）。我这台 Kwrt
自带，装完就能用；万一你那边页面 500，`opkg install luci-compat` 再试。

### 手工拷文件

不想装包、或者想改源码的话：

```sh
opkg update && opkg install curl ca-bundle

scp -O root/usr/bin/wifilogin.sh          root@192.168.1.1:/usr/bin/wifilogin.sh
scp -O root/etc/init.d/wifilogin          root@192.168.1.1:/etc/init.d/wifilogin
scp -O root/etc/config/wifilogin          root@192.168.1.1:/etc/config/wifilogin
scp -O root/etc/hotplug.d/iface/90-wifilogin root@192.168.1.1:/etc/hotplug.d/iface/90-wifilogin
```

（上面是仓库里的相对路径，照你本地实际位置改。）

然后补权限：

```sh
chmod +x /usr/bin/wifilogin.sh /etc/init.d/wifilogin /etc/hotplug.d/iface/90-wifilogin
chmod 600 /etc/config/wifilogin     # 里面有明文密码
```

想要网页就把 `luasrc/` 下那三个文件也拷到 `/usr/lib/lua/luci/` 对应位置（路径见上表）。
目标目录不一定存在，先建出来：

```sh
mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/model/cbi/wifilogin /usr/lib/lua/luci/view/wifilogin
```

不拷也能跑，只是没界面。

配置里加账号：

```
vi /etc/config/wifilogin
```

```uci
config wifilogin 'main'
	option enabled '1'                 # 开关在 main 段里，不是 account 段
	option portal  ''                  # 留空就靠 AC 探测

config account 'acc1'
	option label    '我的宽带'
	option username '手机号'
	option password '重置后的宽带密码'
```

`enabled`、`portal` 这些是 `main` 段的选项，账号信息才是 `account` 段。写错段了页面读不到。

跑一下看看：

```sh
/usr/bin/wifilogin.sh status
/usr/bin/wifilogin.sh force      # 前台跑一次，过程直接打出来
```

开机自启：

```sh
/etc/init.d/wifilogin enable
/etc/init.d/wifilogin start
```

## 页面

`服务 → Portal 自动登录`：

- **宽带账号**：表格，点「添加」，备注 / 账号 / 密码各一列，行尾有「删除」。一条账号存成一段
  `config account`，不再往 `main` 里堆。
- **当前使用的账号**：下拉框，选哪段用哪段。选「自动」或留空就用第一条。新加的账号要保存后
  **重新打开页面**才会出现在下拉里——那个列表是服务端按 uci 现读的。
- **启用自动登录**：关掉后 `check` 和 daemon 都不动，但手动按钮还能点。
- **自动探测 AC 下发的登录地址**：默认开。没认证时 AC 会把请求 302 到带 `wlanuserip`、
  `wlanacname`、`user-mac` 的地址，脚本直接抓这个用，省得自己拼，换了网段也不会错。抓不到才用下面填的。
- **网关（Portal）地址**：后备选项。只有关掉上面那个开关，或者 AC 不回 302 时才用得上。
  三种写法都认：`10.1.2.3:8080`、`http://10.1.2.3:8080/`、或者把浏览器里那串
  `showLogin.do?...` 原样粘进来。留空就只靠探测，探测不到时再拿接口的 IP/MAC 自己拼。注意：**同时关掉自动探测、
地址又留空**的话，脚本会直接报「没有可用的 Portal 地址」然后放弃。
- **检测间隔、免密**：都在页面上，不用再 SSH 改文件。
- **立即登录 / 仅检测状态 / 测试网关 / 诊断**：分别对应 `force` / `status` / `testportal` / `diag`，
  输出会贴回页面下面。「测试网关」只 GET 一次登录页，不提交账号、也不影响失败计数，改完地址想先
  确认通不通就点它。「诊断」会收集接口地址、路由表、ping、`curl -v`、最近日志，网络有问题（比如
  `HTTP 000`）先看这个，比一句「网络异常」有用得多。

点一次「立即登录」一般几秒出结果，最坏要一分钟左右（在线探测 16s + 门户探测 16s + GET 10s +
POST 15s + 提交后再探 16s），转圈别急着刷新。

表单保存后会自动 `/etc/init.d/wifilogin reload`。

账号是按这个顺序找的：`main.active` 指向的段 → 老的 `main.username` → 第一条 `config account`。
都没有就不登录，日志里写「未配置宽带账号」——省得拿空账号去撞验证码。

## 自动认证怎么跑的

```
每 60 秒探一次 http://connect.rom.miui.com/generate_204
  ├─ 返回 204            → 在线，接着睡
  └─ 不是 204 / 被劫持   → 走登录
        GET  <网关>/showLogin.do    拿 portalsessionid 和 CSRFHW
        POST /login.do              bpssUSERNAME + bpssBUSPWD（明文）
        再探一次 → 204 就算成功
```

成功与否看的是「能不能上网」，不是去解析成功页的文案——成功页每个学校的都不一样，而且我之前就有弹出了成功页面实际上没有网络的情况。

开机的时候是 procd 拉起 `daemon`，它先等 5 秒，然后就是上面这个循环。另外
`90-wifilogin` 在接口 up 时也会立刻触发一次 `check`，因为开机那一刻 WiFi 还没关联上，
光等 daemon 的周期会慢一拍。

## 别把账号撞锁了

这个 Portal 锁账号的判断（实测）：

| 情况 | 服务端怎么反应 | 脚本怎么办 |
|---|---|---|
| 密码错 | 回 `用户名或密码错误` | 计数，**3 次后停 30 分钟** |
| 连续失败 5 次 | 账号锁 10 分钟，按账号算 | 看到「锁定」字样就停 15 分钟 |
| 失败后再提交 | 强制要验证码 | 脚本不处理验证码，停 5 分钟 |

**别写 `while true; do curl ...; done` 这种**，5 次就把号锁了。脚本里的退避是特意加的，
别嫌慢就删。反复点「立即登录」也照样累计失败次数，密码确认对了再点。

## 常见问题

### 卡在「验证码输入错误」出不来

服务端连续看到失败之后会强制要求验证码，而脚本提交的 `bpssVERIFY` 一直是空的，所以会重复
「退避 5 分钟 → 再试 → 又要验证码」，永远出不来。只能人工介入一次：

1. 用手机或电脑连这个 WiFi（或者干脆连上游校园网）；
2. 浏览器随便开个网页，等它跳到 Portal，账号密码加验证码填对，登录成功；
3. 回路由器点「立即登录」。

验证码状态是按账号/IP 记的，手动成功一次就消了。要是脚本反复被要验证码，多半是前面哪次密码填错了，
先把密码确认对。

### 出现的问题：`HTTP 000` / `Network unreachable` / `curl: (7) ... after 0 ms`

`curl` 0 毫秒就失败，说明包根本没发出去。看一眼 `ip route`，如果只有 link-scope 那几条、
**没有 `default`**，那就是路由器没拿到网关，连 Portal 都够不着，跟账号密码、跟脚本都没关系。

`ip -4 addr` 里 `phy1-sta0`（WISP 的 STA 口，名字随机器不同，`iw dev` 能看出来）有 IP 也没用——
那只是二层拿到的地址，没默认路由照样出不去。常见的几种原因：

- WISP 接口是 `proto static`，但没填网关
- 上游 DHCP 没下发 option 3（网关），lease 里只有 IP
- STA 设备没归到 `wwan` 网络，或者接口上写了 `option defaultroute '0'`

先手工验一下（网关按实际填，一般就是网段里第一个地址）：

```sh
ping -c2 192.168.100.1
ip route add default via 192.168.100.1 dev phy1-sta0
curl -s -o /dev/null -w '%{http_code}\n' http://10.1.2.3:8080/showLogin.do
ip route del default via 192.168.100.1 dev phy1-sta0
```

`ping` 不通先别急着换网关——不少校园网直接封了 ICMP，网关是对的也 100% 丢包（我这边就是）。
判断依据看 `ip neigh` 里网关那条是不是 `REACHABLE`，或者直接看第三条 curl 通不通。

第三条回 `200` 就说明链路没问题，纯粹缺默认路由。补的时候分两种情况：

接口是 `proto static`，直接给接口加网关：

```sh
uci set network.wwan.gateway='192.168.100.1'
uci commit network && ifup wwan
```

接口是 `proto dhcp`（上游不发网关时）——给接口设 `gateway` 是不生效的，得加一条独立路由：

```sh
uci add network route
uci set network.@route[-1].interface='wwan'
uci set network.@route[-1].target='0.0.0.0'
uci set network.@route[-1].netmask='0.0.0.0'
uci set network.@route[-1].gateway='192.168.100.1'
uci commit network && ifup wwan
```

验证一下 `ip route | grep default` 有输出就行了。

顺便，`run_once` 先探在线、不在线才查默认路由，没有就直接在日志里写「没有默认路由…检查 WISP/上游 WiFi」，
「诊断」里也有这一行。

### 登录地址必须带 `wlanuserip` / `user-mac`

Portal 的登录页网址大概长这样：

```
http://10.1.2.3:8080/showLogin.do?wlanuserip=10.0.0.5&wlanacname=0015.0000.000.00&user-mac=aa-bb-cc-dd-ee-ff
```

`wlanuserip` 是 **AC 看到的客户端 IP**，`user-mac` 是客户端的 MAC，`wlanacname` 是 AC 编号。
少了这几个参数，服务端不知道给谁放行，登录就白登。

脚本取地址的顺序（`portal_urls`）：

1. 先用 `CHECK_URL` / `CHECK_URL2` 探一下，没认证时 AC 会 302 到带全部参数的登录页，抓
   `Location` 直接用（**默认就这么干**，IP/MAC/AC 名一次全齐）；
2. 抓不到（已经认证了，或者上游不返回 302）才看你在「网关地址」里填的：带 `?` 的完整链接原样用，
   只填 IP:端口 就补 `/showLogin.do`；
3. 还是没有参数，才自己拼：取默认路由所在接口的 IP/MAC，加上可选的「AC 名称」。

所以正常情况下什么都不用填，AC 会 302 就够了。只有第 1 步不成立（上游不返回 302、只返一个 200
的劫持页）时，才需要把「AC 名称」补上。不想要探测就把页面上那个开关关掉。

「诊断」里会打印实际用的地址（`登录页  = ...`，注意是两个空格），正常登录时日志里打的是
「认证地址: ...」。登录失败先看这行有没有 `wlanuserip`。

## 前提：必须是 WISP / NAT 模式

这是最容易踩的坑：

- ✅ **WISP / 中继(NAT)**：路由器用 station 模式连上游 WiFi，自己拿一个 IP 再做 NAT。AC 看到的是
  路由器的 IP/MAC，路由器登一次，下面全部共享。
- ❌ **无线中继 / relayd / 桥接**：路由器只是透明转发，终端直接拿上游 IP，每台设备都得各自认证，
  路由器代劳不了。

确认办法：`iw dev` 看有没有 station 接口，`ip addr` 看 `wwan` / `phy1-sta0` 有没有拿到 IP。

## 一点注意事项

- **密码必须是重置过的**。这个请参照各自校园网登陆页面的重置步骤，每个学校的可能都不一样，仅供参考。
- 理论上勾过「自动登录」（`macsave=1`）之后，服务端会做 MAC 绑定，1/6/12 个月内可能都不用再认证，这时候服务其实可以停掉（但我们学校的校园网不知道为啥行不通，好神奇啊，盲猜学校土豆服务器的问题）。
- 密码是明文走 HTTP 的，`chmod 600` 只是最低限度的保护。别在公共设备上跑（只能说给我们学校写这校园网认证的脑子秀逗了）。
- 改检测频率就动 `option interval`，不建议低于 30 秒，Portal 那边可能有频率限制。
- `/etc/init.d/wifilogin status` 输出 `online` 或 `offline (fails=N)`，N 是连续失败次数。
- 调试看这几样：`cat /tmp/wifilogin/last_response.html` 是服务端原始返回，
  `logread -e wifilogin` 是日志，`cat /tmp/wifilogin/manual.log` 是最近一次从页面点出来的结果。

## 卸载

```sh
/etc/init.d/wifilogin disable
/etc/init.d/wifilogin stop
opkg remove wifilogin
```

`/etc/config/wifilogin` 里存着账号密码，opkg 按惯例会当作配置文件保留。不想要就
`rm -f /etc/config/wifilogin`，顺手把 `/tmp/wifilogin` 也删了。

## 兼容性

在刷了 Kwrt 24.10（LuCI 24.10 + luci-compat）的 Cudy TR3000 上跑通了。理论上 OpenWrt 21.02 及以上都行：脚本只依赖
busybox ash、`uci` 和 `curl`，页面依赖 luci-compat。新版纯 JS LuCI 如果没装 luci-compat，菜单能注册
上，但点进去会报错——`opkg install luci-compat` 就好。

## 自己打包和发版

欢迎各位来给我弄的东西查漏补缺，改完源码记得递增一下版本号再打包，例如：

```sh
python build_ipk.py 0.1.1
```

会按正确权限（脚本 755、配置 600、lua/htm 644）把文件打进 tar.gz，并且**连父目录条目一起打**
（typeflag=5）。busybox 的 tar 不会自动建父目录，少了目录条目 opkg 就报
`wfopen: ...: No such file or directory`（别问我咋知道的）。control 里声明了
`Depends: luci-base, luci-compat`，postinst 会清一次 LuCI 缓存。

如果你 fork 了这个仓库准备自己发，记得把 README 里的 `justicelee114514` 换成你自己的用户名：

```sh
sed -i 's/justicelee114514/你的用户名/g' README.md
```

发布就三条命令：

```sh
git add -A && git commit -m "0.1.1"
git tag -a v0.1.1 -m "0.1.1"
git push && git push --tags
```

然后去 GitHub 上 Releases → Draft a new release，选刚推的 tag，标题写版本号，正文列一下改了什么，
附件传**两份**：

- `wifilogin_0.1.1_all.ipk` —— 带版本号，留档用；
- `wifilogin_all.ipk` —— 同内容复制一份，名字不带版本号。

README 里那条 `latest/download/wifilogin_all.ipk` 靠第二份才能一直有效：`latest` 只跟着 tag 走，
不跟文件名走。只传带版本号那份的话，下次发版这条链接就 404 了。

## 不想用 procd 的话

cron 也行，间隔别太密：

```
*/2 * * * * /usr/bin/wifilogin.sh check >/dev/null 2>&1
```

## 许可证

Copyright (C) 2026 wifilogin contributors

本项目以 **GNU Affero General Public License v3.0**（AGPL-3.0-or-later）发布，协议全文见 [LICENSE](LICENSE)。
所有源文件开头均有 `SPDX-License-Identifier: AGPL-3.0-or-later` 标识符。

该软件可以自由使用、修改、再分发，但分发修改版时必须同样以 AGPLv3 开放源码，并保留版权声明；不提供任何担保。

把本软件或更改过的版本用网络提供服务给别人时，也应分发对应源码。编进路由器固件再分发也同样算分发，须一并提供源码。
