# OpenWrt-Mihomo

> Fork/改造自 [douglarek/mihomo-openwrt](https://github.com/douglarek/mihomo-openwrt)：mihomo 包主体与 CI 构建流程引自该项目，本仓库新增 LuCI 管理界面并合并为单仓库扁平结构。上游功能未做删改。

## 仓库内容

```
openwrt-mihomo/
├── mihomo/            # mihomo 包：/usr/bin/mihomo、/etc/init.d/mihomo、/etc/config/mihomo
│                      #             /etc/mihomo/example.yaml 与 Country.mmdb（打包时自动下载）
└── luci-app-mihomo/   # LuCI 管理界面（依赖 mihomo 包，编译时自动先编译 mihomo）
                       # 另随装 /etc/mihomo/config.sh    （「配置文件」页的导入/更新辅助脚本）
                       #       /etc/mihomo/autoupdate.sh（定时更新的计划任务管理脚本）
                       #       /etc/mihomo/autorestart.sh（定时重启服务的计划任务管理脚本）
                       #       /etc/mihomo/tproxy.sh    （透明代理的 fwmark 策略路由脚本）
                       #       /etc/mihomo/clash.nft    （透明代理的 nft 规则，独立表 inet clash）
```

`.ci/prune-releases.sh` 是发版后裁剪旧 Release 的脚本（只保留最新 5 个），由 `build.yml` 自动调用。

面向 OpenWrt 25 的原生 mihomo 构建（APK 包格式），自带 procd init 脚本与 uci 配置；打包时自动下载 [Loyalsoldier](https://github.com/Loyalsoldier/geoip) 的 `Country.mmdb`，安装即含，无需首次运行在线下载。

## 安装

前置要求：OpenWrt 25.12.2+，并了解 [mihomo 配置](https://wiki.metacubex.one/config/) 的基本写法。

两个包需配套安装（LuCI 界面直接操作本项目的 uci 配置、init.d 命令与透明代理脚本，不兼容其他来源的 mihomo）：

```
$ apk add --allow-untrusted mihomo-1.19.31-r2_x86_64.apk luci-app-mihomo-1.0.3-r4.apk
```

APK 会自动安装 kmod-tun、kmod-inet-diag、kmod-netlink-diag 等内核依赖；luci-app-mihomo 与架构无关（文件名不带架构后缀），两个架构通用。全部版本见 [Releases](https://github.com/hahaher123/openwrt-mihomo/releases)。

## Country.mmdb

`/etc/mihomo/Country.mmdb` 在打包时从 [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip) 下载并随包发布，安装即含，无需首次运行在线下载；之后由 mihomo 自己按 `geo-auto-update` 更新。`geodata-mode: false`（默认）时 GEOIP 规则读的就是它。

## LuCI 界面

服务 → Mihomo，五个页面：

| 页面 | 功能 |
| --- | --- |
| 运行状态 | 服务状态 / PID / 开机自启 / 程序版本（5 秒刷新）；一键启停；运行日志面板（最新 200 行、可逐页上翻回查到日志开头、日志存放位置与文件大小、可清空、可改上限） |
| 运行参数 | 编辑 `/etc/config/mihomo`：enabled、conffile、workdir、user、ifaces、日志开关、dashboard；保存并应用即重启生效 |
| 透明代理 | 开关透明代理（启动前加载策略路由与 nft 规则，停止时移除）；在线编辑 `tproxy.sh` / `clash.nft`；一键检查规则状态 |
| 配置文件 | 列出 / 编辑 / 校验 / 切换 workdir 下的配置文件；远程导入订阅；仅更新与定时更新服务器和代理组 |
| 后台管理 | 内嵌 external-ui 仪表盘（metacubexd / yacd 等），默认走同源反代 `/mihomo-ui/`（nginx locations 随包自带，http/https 自适应，https 下不被浏览器混合内容策略拦截）；可在「运行参数」页改回直连地址（如 `http://<路由器>:9090/ui`） |

**启动输出与排障**（`/etc/init.d/mihomo`）：

- 进度走 stdout、错误走 stderr，手工执行直接可见；被脚本 / cron 调用时可自行 `2>&1 | logger -t xxx`
- 错误同时写 syslog（标签 `mihomo`），开机阶段 stdout 无去处时也能在 `logread` 里查到
- **mihomo 进程输出默认写入日志文件**（`log_file`，默认 `/var/log/mihomo.log`），不写系统日志（`log_stdout`/`log_stderr` 默认 0）：mihomo 每个连接都打一行 info 日志，转发会刷满 `logread`。写文件还能保留历史，重启 LuCI 或换浏览器登录后仍可回查
- 默认路径 `/var/log/mihomo.log` 在 `/tmp`（内存盘）上：重启后清空、不磨损 flash；要跨重启保留可改到 `/etc/mihomo/` 下的路径（会写 flash，慎用）
- 日志面板默认显示最新 200 行；点「加载更早的日志」逐页前插，可一直翻到日志开头，「回到最新」恢复跟随。翻历史时自动暂停刷新（否则新写入的日志会把正在看的内容顶走），日志被裁剪后自动退回最新
- 日志文件超过 `log_max_kb`（默认 1024 KB）时只保留最新部分：服务启动时裁剪一次，日志面板每次刷新也会检查一次。清空与改上限都在「运行状态」页的日志面板里操作，改上限不重启服务
- 想彻底不落盘：把 `log_file` 设为 `/dev/null`（启动命令会退回直连启动，不再经过 `sh -c` 重定向）
- **启动失败返回非 0**（经 `service_started` 钩子带出，rc.common 不会再把它吃成 0），因此 `restart && 后续动作` 与 cron 判断都可信
- 启动前用 `mihomo -t` 校验配置：失败只打印 mihomo 的错误行并放弃启动，避免 procd 反复 respawn 刷屏；临时跳过校验 `uci set mihomo.main.config_test=0`（或环境变量 `MIHOMO_SKIP_CONFIG_TEST=1`）
- `/etc/init.d/mihomo diag`：一次打印二进制版本、uci 全部取值、关键文件（含缺失项）、procd 状态与最近日志
- 二进制可用环境变量 `MIHOMO_BIN` 顶替，便于拿开发版试启动

**配置文件页要点**：

- **校验先行**：保存 / 保存并重启 / 远程导入都先用 `mihomo -t` 校验（参数与服务启动一致，在 `/tmp` 进行），不通过不写盘；配置文件权限 `0600`（含订阅凭据）
- **远程导入**：下载到 `/tmp` → 校验 → 安装，任何一步失败不落盘、不覆盖同名文件；gzip / base64 订阅自动解码
- **仅更新 / 定时更新**：按订阅重拉后只替换 `proxies` 与 `proxy-groups` 两段，其余内容原样保留；与本地一致时不写盘不重启，有变化才写入并重启服务。订阅链接记录在 `<workdir>/sources`，更新无需重填。定时更新即把同一流程挂为 cron（只写在页面管理的标记块里，不影响手工 crontab），结果写入系统日志（标签 `mihomo-autoupdate`）
- **定时重启服务**：低峰时段自动 `restart` mihomo（释放连接状态与内存），同一套 cron 标记块机制，不影响手工 crontab 与定时更新任务

> [!NOTE]
> 导入 / 更新依赖路由器能直连订阅地址；若订阅需经代理访问，请先配置好网络出口。下载优先用 `curl`（超时与重试内置），失败原因会归纳为一句中文提示；若返回的是网页或 `ss:// vmess://` 节点列表，请改用机场的 Clash 订阅地址（常见做法是链接后加 `&flag=clash`）。

## 透明代理（nft REDIRECT + TPROXY 混合模式）

**不使用 TUN 模式**，不需要 `tun:` 配置块与 `auto-redirect`：init.d 在 mihomo 启动前加载 `/etc/mihomo/clash.nft`（独立表 `inet clash`），服务停止时自动移除，转发流量与路由器自身流量均覆盖：

| 流量 | 处理方式 | 落点 |
|---|---|---|
| 转发 TCP（prerouting） | nat 链 `redirect` | `redir-port` **7893** |
| 转发 UDP（filter prerouting） | `tproxy` + fwmark `0x100` | `tproxy-port` **7894** |
| 本机 TCP / UDP | 同上，经 output 链进入 | 7893 / 7894 |

`/etc/mihomo/config.yaml` 必须同时启用两个入口端口，且与 `clash.nft` 保持一致：

```yaml
redir-port: 7893    # TCP REDIRECT 入口
tproxy-port: 7894   # UDP TPROXY 入口（两端口不能相同，绑同口会报 Address already in use）
```

- **不要启用 `tun:`**，也不要保留旧版 fw4 include `/etc/nftables.d/11-clash.nft`——都会与独立表重复改写路由 / 流量
- 分流由 `clash.nft` 顶部的 `proxy_ip` 集合决定：默认含 fake-ip 段 `198.18.0.0/16`，配合 `dns.enhanced-mode: fake-ip` 自动捕获；按真实 IP 分流需自行把目标网段加入集合
- 排查：nft 加载是**整体原子操作**，任意一行报错则整个文件不生效；`nft list table inet clash` 的 packets 计数为 0 说明流量未匹配

更多用法见原作者的 [gist 笔记](https://gist.github.com/douglarek/99fb8d7f30fac2a6d2e9a32a47296e30)。

## 构建

本仓库不在任何 feed 中，用 git clone 取源码，在 OpenWrt 25.12.2 SDK 中构建（与 CI 步骤一致）：

```sh
git clone https://github.com/hahaher123/openwrt-mihomo
# 下载对应架构的 SDK（https://downloads.openwrt.org/releases/25.12.2/targets/）并解压，进入 SDK 根目录

./scripts/feeds update -a
./scripts/feeds install -a
cp -a /path/to/openwrt-mihomo/mihomo /path/to/openwrt-mihomo/luci-app-mihomo package/
make defconfig    # 或用发行版 targets 页的 config.buildinfo 作为 .config

make package/mihomo/{download,check} FIXUP=1 V=s   # 预取地理数据库（Download/ 块）
make package/luci-app-mihomo/compile V=s           # 硬依赖 +mihomo，自动先编译 mihomo
```

> [!IMPORTANT]
> 2024 年 11 月起 OpenWrt 默认使用 apk 包管理器，本仓库仅支持构建 APK 包，不再支持 IPK。

## 发布

推送 main 且**任一 Makefile 的版本号**（`PKG_VERSION` / `PKG_RELEASE`）变化时，自动构建并发布 Release（按 tag 判重，同版本不重复构建）；也可在 [Actions → Build and release Mihomo APK](https://github.com/hahaher123/openwrt-mihomo/actions/workflows/build.yml) 手动 Run workflow 重跑（勾选 force 可在版本未变时强制重建并覆盖资产）。产物含 x86_64 与 aarch64_generic 两个架构。

- **tag 规则**：`v<mihomo 版本>-r<修订>-luci<LuCI 版本>-r<修订>`，当前对应 `v1.19.33-r3-luci1.0.5-r2`
- **版本号约定**：修 bug / 调整已安装文件只升 `PKG_RELEASE`；新增功能或跟进上游版本升 `PKG_VERSION` 并把 `PKG_RELEASE` 重置为 `1`；只改文档或 CI 不动版本号
- **Release 保留策略**：只保留最新 **5** 个 Release，更旧的连同其 APK 资产自动删除（git tag 保留，故历史版本仍可追溯、可按 tag 自行构建）。清理由每次发版后自动执行，无需人工干预；需要单独补跑时用 [Actions → Prune old releases](https://github.com/hahaher123/openwrt-mihomo/actions/workflows/prune-releases.yml)（不触发构建，可指定保留数量）
- **上游自动跟进**：每周一 10:17（北京时间）探测 MetaCubeX/mihomo 的最新正式版，高于当前 `PKG_VERSION` 时自动升版本、推送并触发构建发布

上游原版构建产物见 [douglarek/vanilla-mihomo releases](https://github.com/douglarek/vanilla-mihomo/releases)。
