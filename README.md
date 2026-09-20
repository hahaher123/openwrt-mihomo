# OpenWrt-Mihomo

> Fork/改造自 [douglarek/mihomo-openwrt](https://github.com/douglarek/mihomo-openwrt)——mihomo 包主体与 CI 构建流程均引自该项目，感谢原作者 [@douglarek](https://github.com/douglarek)。
> 本仓库为个人自用改造版：新增 LuCI 管理界面，并将两个包合并为单仓库扁平结构。上游功能未做删改，原版见上述仓库。

## 仓库内容

```
openwrt-mihomo/
├── mihomo/            # mihomo 包：/usr/bin/mihomo、/etc/init.d/mihomo、/etc/config/mihomo
│                      #             /etc/mihomo/example.yaml 与地理数据库
│                      #             （Country.mmdb、geoip.dat、geosite.dat，打包时自动下载）
└── luci-app-mihomo/   # LuCI 管理界面（依赖 mihomo 包，编译时自动先编译 mihomo）
                       # 另随装 /etc/mihomo/config.sh    （「配置文件」页的导入/更新辅助脚本）
                       #       /etc/mihomo/autoupdate.sh（定时更新的计划任务管理脚本）
                       #       /etc/mihomo/tproxy.sh    （透明代理的 fwmark 策略路由脚本）
                       #       /etc/mihomo/clash.nft    （透明代理的 nft 规则，独立表 inet clash）
```

- 面向 OpenWrt 25 的原生 mihomo 构建（APK 包格式），自带 procd init 脚本与 uci 配置
- **内置地理数据库**：打包时自动下载 [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip) 的 `Country.mmdb` 与 [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) 的 `geoip.dat`、`geosite.dat`（经 jsdelivr CDN），安装时释放至 `/etc/mihomo`，无需首次运行时在线下载
- `luci-app-mihomo` 通过 `LUCI_DEPENDS:=+luci-base +mihomo +curl` 声明依赖；`curl` 是下载订阅的首选工具（自带 TLS 与 CA），缺失时会依次退回 `wget`、`uclient-fetch`

## 前置要求

* OpenWrt 25.12.2+
* 了解 OpenWrt 基本操作，以及基本的 [mihomo 配置](https://wiki.metacubex.one/config/)

## LuCI 界面功能

服务 → Mihomo，共五个页面（菜单顺序：运行状态 → 运行参数 → 透明代理 → 配置文件 → 后台管理）。

**「运行状态」** 实时显示服务状态、进程 PID、开机自启、mihomo 程序版本（每 5 秒刷新）；一键启动 / 停止 / 重启；查看最近 50 行系统日志。

**「运行参数」** 编辑 `/etc/config/mihomo`：`enabled`（开机自启）、`conffile`（配置文件，默认 `/etc/mihomo/config.yaml`）、`workdir`（工作目录，默认 `/etc/mihomo`）、`user`（运行用户，使用透明代理时请保持 root）、`ifaces`（监听接口，网络变动时自动重启）、`log_stdout` / `log_stderr`、`dashboard`（后台管理地址）。点击「保存并应用」会重启服务生效。

**「透明代理」** 开关 uci `transparent`：开启后在 mihomo **启动前**加载 fwmark 策略路由与 nft 规则（`/etc/mihomo/tproxy.sh start` + `clash.nft`，独立表 `inet clash`），**服务停止时自动移除**。可在线编辑 `tproxy.sh` 与 `clash.nft`（保存后重启生效）；「检查规则状态」调用 init.d 的 `tproxystatus`，显示当前 `ip rule`、路由表 256 与 nft 表内容。

**「配置文件」** 管理 workdir 下的 `*.yaml` / `*.yml`：列出文件、单选其中一项作为运行配置、直接编辑其内容。

- **远程导入**：填 clash/mihomo 订阅 URL，由包内 `/etc/mihomo/config.sh import` 完成——先下载到 `/tmp`，用 `mihomo -t` 校验通过后才安装到 `/etc/mihomo`；**下载失败或校验失败不会落盘，也不会覆盖同名文件**（需显式勾选「覆盖同名文件」）。文件名留空则按 URL 末段自动命名并补 `.yaml`
- **仅更新服务器和代理组**：按订阅链接重新拉取，**只替换选中配置里的 `proxies`（服务器）与 `proxy-groups`（代理组）两段**，其余设置（`rules` / `dns` / `tun` 等）以及手动修改过的内容全部原样保留——适合「本地手工调过规则、只想刷新节点」的场景。流程为 下载 → 提取两段 → 与本地对比 → `mihomo -t` 校验 → 通过才写回：**两段与本地一致时直接结束，既不写盘也不重启**（避免每天白白重启一次代理），只有内容确实有变化时才写入并重启服务（仅当更新的正是当前生效配置、且服务正在运行时），让新节点立即生效。任何一步失败都不改动原文件并给出具体原因（网络 / DNS 解析 / HTTP 状态 / 订阅格式 / 配置解析 / 校验不通过）。订阅链接在导入时记录于 `<workdir>/sources`（0600），更新时无需重填
- **定时更新服务器和代理组**：把「仅更新」写成一条 cron 计划任务，频率可选每小时 / 每 6 小时 / 每 12 小时 / 每天 / 每周一，也可填任意 5 段 cron 表达式。计划任务只写在 `/etc/crontabs/root` 内由页面管理的标记块里，**你自己添加的其它计划任务不受影响**；每次执行的结果与失败原因写入系统日志（`logread`，标签 `mihomo-autoupdate`）。定时更新走与「仅更新」完全相同的流程，同样会先对比：**内容一致时什么都不做**，内容有变化才更新配置并重启服务；不会改动其它设置
- **选择运行配置**：「设为当前配置」写 uci `mihomo.main.conffile`（与 `/etc/init.d/mihomo` 同源），「…并重启」写入后再重启服务；列表中用绿色标签标出当前生效文件
- **编辑与保存**：提供「校验」/「保存」/「保存并重启」三个按钮。**保存与保存并重启都会先校验，校验不通过不会写入文件**；校验参数与服务启动一致（`mihomo -t -f <配置> -d <workdir>`），且在 `/tmp` 中进行，不写 flash；保存后文件权限 `0600`（配置含订阅凭据）
- **结果提示**：所有操作的结论（校验 / 保存 / 重启 / 导入 / 更新 / 定时设置）都以页面顶部**醒目横幅**呈现（颜色区分成功 / 失败 / 警告）并附脚本原始输出，同时弹出通知

**「后台管理」** 内嵌 mihomo 外部控制器的 Web 管理界面（metacubexd / yacd 等），默认 `http://<路由器地址>:9090/ui`（可在「运行参数」页修改），提供「在新窗口打开」与「重新加载」。使用前需在 mihomo 配置文件中启用 `external-controller`（如 `0.0.0.0:9090`）与 `external-ui`（如 `ui`），并把仪表盘文件放入对应目录。

> [!NOTE]
> 远程导入 / 更新依赖路由器能直连订阅地址；若订阅地址需经代理访问，请先配置好网络出口。
>
> **下载**：优先用 `curl`（连接超时 15s / 整体超时 60s），最多重试 3 次，每次等待翻倍（5s → 10s → 20s，上限 30s）；5xx / 408 / 429 与超时、断连会重试，其余 4xx 与证书错误直接失败（重试也不会好）。失败原因会被归纳成一句中文（域名解析失败 / 网络连接失败 / 连接超时 / HTTP 4xx·5xx / TLS 证书错误）。
>
> **订阅格式**：同一份订阅可能不是明文 YAML——`gzip` 压缩与 `base64` 编码会被自动识别并解码；若链接返回的是网页（登录页/错误页）或 v2ray 那种 `ss:// vmess://` 节点链接列表，会直接给出可读原因（后者需改用机场的 Clash 订阅地址，常见做法是在链接后加 `&flag=clash`），而不是抛出难懂的 YAML 报错。

## 透明代理配置（nft REDIRECT + TPROXY 混合模式）

本项目**不使用 TUN 模式**，也不需要 `tun:` 配置块与 `auto-redirect`：规则由 init.d 在 mihomo 启动前加载 `/etc/mihomo/clash.nft`（独立表 `inet clash`），**转发流量与路由器自身流量均覆盖**：

| 流量 | 处理方式 | 落点 |
|---|---|---|
| 转发 TCP（prerouting） | nat 链 `redirect` | `redir-port` **7893** |
| 转发 UDP（filter prerouting） | `tproxy` + fwmark `0x100` | `tproxy-port` **7894** |
| 本机 TCP（nat output） | nat 链 `redirect` | `redir-port` 7893 |
| 本机 UDP（route output） | 打 mark 回环，再被 prerouting 的 tproxy 接住 | `tproxy-port` 7894 |

`redirect` 是 NAT 语句、`tproxy` 只能用于 filter 类型的 prerouting 链，两者语法上无法混在一条链里，因此 `clash.nft` 拆成 nat / filter 两组链。

`/etc/mihomo/config.yaml` 必须同时启用两个入口端口，且与 `clash.nft` 中的 `:7893` / `:7894` 保持一致：

```yaml
redir-port: 7893    # TCP REDIRECT 入口（对应 clash.nft: redirect to :7893）
tproxy-port: 7894   # UDP TPROXY 入口（对应 clash.nft: tproxy ip to :7894）
```

- **两个端口不能相同**：redir 与 tproxy 是两个独立监听器，绑同一端口会报 `Address already in use`
- init.d 启动时会检查这两个端口，缺失则在系统日志给出警告
- **不要启用 `tun:`**，也不要在路由器上保留旧版 fw4 include `/etc/nftables.d/11-clash.nft`——两者都会与独立表重复改写路由 / 流量
- 分流由 `clash.nft` 顶部的 `proxy_ip` 集合决定，只有命中该集合的流量才进入 mihomo：默认含 fake-ip 段 `198.18.0.0/16`，配合 `dns.enhanced-mode: fake-ip` 即可自动捕获；若按真实 IP 分流，需自行把目标网段加入集合

**使用步骤**：确认「运行参数」页的路径 → 在配置里加上 `redir-port` / `tproxy-port` → 打开「透明代理」开关并保存应用 → 用「检查规则状态」确认 `ip rule`、路由表 256 与 `inet clash` 表已就位。

**排查**：规则未生效先看系统日志有无 `failed to load /etc/mihomo/clash.nft`——nft 加载是**整体原子操作，任意一行报错则整个文件都不生效**；`nft list table inet clash` 可看每条规则的 `packets/bytes` 计数，为 0 说明流量未匹配。编辑规则时注意 `redirect` / `accept` / `drop` 属**终止语句**，必须放在规则**最后**，正确写法：`... counter redirect to :7893 comment "proxy-tcp-redirect"`。

更多用法可参考原作者的 [gist 笔记](https://gist.github.com/douglarek/99fb8d7f30fac2a6d2e9a32a47296e30)。

## 构建

在 OpenWrt 25.12.2 SDK 中：

```
./scripts/feeds update -a
./scripts/feeds install luci
cp -a mihomo luci-app-mihomo package/
make package/luci-app-mihomo/compile V=s   # 会自动先编译 mihomo
```

> [!IMPORTANT]
> 2024 年 11 月起 OpenWrt 默认使用 apk 包管理器，本仓库仅支持构建 APK 包，不再支持 IPK。

## 下载与发布

发布由**手动触发**的 GitHub Actions 工作流完成，一次构建并发布两个包：打开 [Actions → Build and release Mihomo APK](https://github.com/hahaher123/openwrt-mihomo/actions/workflows/build.yml)，点右上角 **Run workflow**（分支选 `main`）；构建完成后自动打 tag 并发布 [Release](https://github.com/hahaher123/openwrt-mihomo/releases)，产物含 x86_64 与 aarch64_generic 两个架构。

**tag 规则**：`v<mihomo 版本>-r<包修订>-luci<LuCI 版本>-r<包修订>`，当前代码对应 **`v1.19.31-r1-luci1.0.3-r1`**。两个包**任意一个版本变化都会产生新 tag**，因此 Release 始终与代码一致；同一版本重复运行只会覆盖更新已有 Release 的资产，不会出现「看着最新、其实是旧代码」的成品包。

**版本号约定**：修 bug / 调整已安装文件只升 `PKG_RELEASE`；新增功能或跟进上游版本才升 `PKG_VERSION`（并把对应的 `PKG_RELEASE` 重置为 `1`）；只改文档或 CI 不动版本号。

> [!IMPORTANT]
> **配套声明**：`luci-app-mihomo` 是为本项目打包的 mihomo 定制的——界面上的每个开关都直接操作本项目的 uci 配置（`/etc/config/mihomo`）、init.d 命令（含 `tproxystatus`）与 `/etc/mihomo/tproxy.sh`、`/etc/mihomo/clash.nft`。请与**同一 Release 内**的 mihomo 配套安装；若使用其他来源或其他版本的 mihomo，界面需自行适配。本项目也**不会自动跟随** mihomo 上游新版本，升级 mihomo 后需手动适配 LuCI 再重新发版。

安装示例（x86_64；APK 会自动安装 kmod-tun、kmod-inet-diag、kmod-netlink-diag 等内核依赖）：

```
$ apk add --allow-untrusted mihomo-1.19.31-r1_x86_64.apk luci-app-mihomo-1.0.3-r1.apk
```

也可以按上一节在 OpenWrt 25.12.2 SDK 中自行编译（一条命令同时产出两个 APK）。上游原版构建产物见 [douglarek/vanilla-mihomo releases](https://github.com/douglarek/vanilla-mihomo/releases)。
