# OpenWrt-Mihomo

> **来源声明**：本项目 Fork/改造自 [douglarek/mihomo-openwrt](https://github.com/douglarek/mihomo-openwrt)，mihomo 包主体与 CI 构建流程均引自该项目，感谢原作者 [@douglarek](https://github.com/douglarek) 的贡献。
>
> **自用声明**：本仓库为个人自用改造版本，主要变更是新增了 LuCI 管理界面并将两个包合并为单仓库扁平结构。上游功能未做删改，如需上游原版请访问上述原仓库。

## 仓库内容

```
openwrt-mihomo/
├── mihomo/            # mihomo 包（安装 /usr/bin/mihomo、/etc/init.d/mihomo、/etc/config/mihomo）
└── luci-app-mihomo/   # LuCI 管理界面（依赖 mihomo 包，编译时自动先编译 mihomo）
```

- **mihomo 包**：面向 OpenWrt 25 的原生 mihomo 构建（APK 包格式），自带 procd init 脚本与 uci 配置
- **内置地理数据库**：打包时自动下载 [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip) 的 `Country.mmdb` 与 [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) 的 `geoip.dat`、`geosite.dat`（经 jsdelivr CDN），安装时释放至 `/etc/mihomo`，无需 mihomo 首次运行时在线下载
- **luci-app-mihomo**：在 Makefile 中通过 `LUCI_DEPENDS:=+luci-base +mihomo` 声明对 mihomo 的硬依赖，单独编译 LuCI 界面即可自动编译 mihomo

## LuCI 界面功能

服务 → Mihomo，包含两个页面：

**「运行状态」页**
- 实时显示服务运行状态（运行中/未运行）、进程 PID、开机自启开关状态、mihomo 程序版本（每 5 秒自动刷新）
- 一键启动 / 停止 / 重启服务
- 查看最近 50 行 mihomo 相关系统日志

**「运行参数」页**（对应 `/etc/config/mihomo`）
- 开机自启开关（`enabled`）
- 配置文件路径（`conffile`，默认 `/etc/mihomo/config.yaml`）
- 工作目录（`workdir`，默认 `/etc/mihomo`）
- 运行用户（`user`，使用透明代理（REDIRECT/TPROXY）时请保持 root）
- 监听接口列表（`ifaces`，网络变动时自动重启服务）
- 标准输出 / 错误输出写入系统日志开关（`log_stdout` / `log_stderr`）
- 后台管理地址（`dashboard`，供「后台管理」页内嵌使用）

**「后台管理」页**
- 内嵌 mihomo 外部控制器的 Web 管理界面（metacubexd / yacd 等），可视化管理代理节点、规则与连接
- 地址默认 `http://<路由器地址>:9090/ui`，可在「运行参数」页修改
- 提供「在新窗口打开」与「重新加载」按钮
- 使用前需在 mihomo 配置文件中启用 `external-controller`（如 `0.0.0.0:9090`）与 `external-ui`（如 `ui`），并将仪表盘文件放入对应目录

**「透明代理」页**
- 开关控制 uci `transparent` 选项：开启后 mihomo **启动前**自动添加 fwmark 策略路由（执行 `/etc/mihomo/tproxy.sh start`：fwmark 0x100 → 表 256）并加载 nft 规则（`nft -f /etc/mihomo/clash.nft`，独立表 `inet clash`）；**服务停止时自动移除**全部规则
- 混合模式：**TCP 走 REDIRECT**（`redir-port: 7893`，nat 链，无需策略路由）、**UDP 走 TPROXY**（`tproxy-port: 7894`，filter 链 + fwmark 策略路由）
- 在线编辑 `/etc/mihomo/tproxy.sh`（策略路由脚本，start/stop 双模式）与 `/etc/mihomo/clash.nft`（混合模式规则，含代理网段集合 `proxy_ip`），保存后重启服务生效
- 「检查规则状态」按钮：调用 init.d 的 `tproxystatus` 命令，显示当前 `ip rule`、路由表 256 与 nft 表内容，一目了然确认规则是否生效
- 要求 mihomo 配置文件同时设置 `redir-port: 7893` 与 `tproxy-port: 7894`（两个端口不能相同，详见下文「透明代理配置」章节）；启动时若检测到缺失会在系统日志给出警告；**不要**同时保留旧版 fw4 include 文件 `/etc/nftables.d/11-clash.nft`，否则规则重复

**透明代理排查要点**
- 规则未生效先看系统日志有无 `failed to load /etc/mihomo/clash.nft`——nft 加载是**整体原子操作，任意一行报错则整个文件都不生效**（此时不会加到任何规则，看起来就是"启用了但没捕获到流量"）
- `nft list table inet clash` 查看每条规则的 `packets/bytes` 计数：为 0 说明流量未匹配，检查 `proxy_ip` 网段是否覆盖目标地址、以及客户端流量是否真的经路由器转发
- 编辑规则时注意语句顺序：`redirect` / `accept` / `drop` 等属于**终止语句**，必须放在规则的**最后**，其后不能再有 `counter` 等语句，否则报 `Statement after terminal statement has no effect`；而 `comment "..."` 是唯一例外（nft 手册：comment 始终被求值），但它**受限语法约束必须写在规则最末尾**。因此正确写法是 `... counter redirect to :7893 comment "proxy-tcp-redirect"`（counter 在前、redirect 居中、comment 收尾），写成 `... counter comment "xxx" redirect ...` 会报 `syntax error, unexpected redirect`

修改参数后点击「保存并应用」会自动重启服务使其生效（由 init.d 的 `reload_service` 配合完成）。

## 前置要求

* OpenWrt 25.12.2+
* 了解 OpenWrt 基本操作、终端使用，以及基本的 [mihomo 配置](https://wiki.metacubex.one/config/)

## 透明代理配置（nft REDIRECT + TPROXY 混合模式）

本项目的透明代理**不使用 TUN 模式**，也不需要 `tun:` 配置块与 `auto-redirect`：规则由 init.d 在 mihomo 启动前加载 `/etc/mihomo/clash.nft`（独立表 `inet clash`）实现，**转发流量与路由器自身流量均覆盖**：

| 流量 | 处理方式 | 落点 |
|---|---|---|
| 转发 TCP（prerouting） | nat 链 `redirect` | `redir-port` **7893** |
| 转发 UDP（filter prerouting） | `tproxy` + fwmark `0x100` | `tproxy-port` **7894** |
| 本机 TCP（nat output） | nat 链 `redirect` | `redir-port` 7893 |
| 本机 UDP（route output） | 打 mark 回环，再被 prerouting 的 tproxy 接住 | `tproxy-port` 7894 |

> `redirect` 是 NAT 语句、`tproxy` 只能用于 filter 类型的 prerouting 链，两者语法上无法混在一条链里，因此 `clash.nft` 拆成了 nat / filter 两组链。

### mihomo 配置文件要求

`/etc/mihomo/config.yaml` 必须同时启用两个透明代理入口端口，且端口号与 `clash.nft` 中的 `:7893` / `:7894` 保持一致：

```yaml
redir-port: 7893    # TCP REDIRECT 入口（对应 clash.nft: redirect to :7893）
tproxy-port: 7894   # UDP TPROXY 入口（对应 clash.nft: tproxy ip to :7894）
```

- **两个端口不能相同**：mihomo 的 redir 与 tproxy 是两个独立监听器，绑同一端口会报 `Address already in use`
- init.d 启动时会检查配置文件中是否存在这两个端口，缺失则在系统日志给出警告
- **不要启用 `tun:`**：TUN 栈（含 `auto-route` / `auto-redirect` / `dns-hijack`）与本套 nft 规则会同时改写路由与流量，互相干扰，二选一即可

### 分流由 `proxy_ip` 集合决定

`clash.nft` 顶部的 `proxy_ip` 集合列出**需要被代理的目标网段**，只有命中该集合的流量才会进入 mihomo：

- 默认包含 fake-ip 段 `198.18.0.0/16`。若 mihomo 配置 `dns.enhanced-mode: fake-ip`（默认 `fake-ip-range` 即 `198.18.0.1/16`），域名解析结果会落在该网段，从而被规则统一捕获——这是最省心的用法
- 若按真实 IP 分流（`enhanced-mode: redir-host` 或仅按 IP 直连/代理），需把目标网段（如 Telegram、特定 CDN 段）加入 `proxy_ip` 集合，否则规则天然不命中
- `private` 集合用于 UDP 排除内网目标，无需改动

### 使用步骤

1. 在「运行参数」页确认配置文件路径与工作目录（默认 `/etc/mihomo/config.yaml`、`/etc/mihomo`）
2. 编辑 `/etc/mihomo/config.yaml`，加上上面的 `redir-port` / `tproxy-port`
3. 打开「透明代理」页开关（`transparent=1`），保存并应用——服务会重启，规则随之加载
4. 用「检查规则状态」确认 `ip rule`、路由表 256 与 `inet clash` 表均已就位
5. 路由器上**删除**旧的 `/etc/nftables.d/11-clash.nft`（fw4 include 形式），避免与独立表重复加载

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

发布由**手动触发**的 GitHub Actions 工作流完成，一次构建并发布两个包：

1. 打开 [Actions → Build and release Mihomo APK](https://github.com/hahaher123/openwrt-mihomo/actions/workflows/build.yml)
2. 点右上角 **Run workflow**（分支选 `main`）
3. 构建完成后自动打 tag 并发布 [Release](https://github.com/hahaher123/openwrt-mihomo/releases)，产物含 x86_64 与 aarch64_generic 两个架构

**tag 规则**：`v<mihomo 版本>-r<包修订>-luci<LuCI 版本>-r<包修订>`，当前版本为 **`v1.19.31-r1-luci1.0.1-r6`**。两个包**任意一个版本变化都会产生新 tag**，因此 Release 始终与代码一致；同一版本重复运行只会覆盖更新已有 Release 的资产，不会出现「看着最新、其实是旧代码」的成品包。

> [!IMPORTANT]
> **配套声明**：`luci-app-mihomo` 是为本项目打包的 mihomo 定制的——界面上的每个开关都直接操作本项目的 uci 配置项（`/etc/config/mihomo`）、init.d 命令（`/etc/init.d/mihomo`，含 `tproxystatus`）与 `/etc/mihomo/tproxy.sh`、`/etc/mihomo/clash.nft`。请与**同一 Release 内**的 mihomo 配套安装；若使用**其他来源或其他版本**的 mihomo，界面需要自行适配。本项目也**不会自动跟随** mihomo 上游新版本，升级 mihomo 后需手动适配 LuCI 再重新发版。

安装示例（x86_64；APK 会自动安装 kmod-tun、kmod-inet-diag、kmod-netlink-diag 等内核依赖）：

```
$ apk add --allow-untrusted mihomo-1.19.31-r1_x86_64.apk luci-app-mihomo-1.0.1-r6.apk
```

也可以按上一节在 OpenWrt 25.12.2 SDK 中自行编译（一条命令同时产出两个 APK）。上游原版构建产物见 [douglarek/vanilla-mihomo releases](https://github.com/douglarek/vanilla-mihomo/releases)。
