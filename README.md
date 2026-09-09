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
- 工作目录（`workdir`，默认 `/usr/share/mihomo`）
- 运行用户（`user`，TUN 模式请保持 root）
- 监听接口列表（`ifaces`，网络变动时自动重启服务）
- 标准输出 / 错误输出写入系统日志开关（`log_stdout` / `log_stderr`）
- 后台管理地址（`dashboard`，供「后台管理」页内嵌使用）

**「后台管理」页**
- 内嵌 mihomo 外部控制器的 Web 管理界面（metacubexd / yacd 等），可视化管理代理节点、规则与连接
- 地址默认 `http://<路由器地址>:9090/ui`，可在「运行参数」页修改
- 提供「在新窗口打开」与「重新加载」按钮
- 使用前需在 mihomo 配置文件中启用 `external-controller`（如 `0.0.0.0:9090`）与 `external-ui`（如 `ui`），并将仪表盘文件放入对应目录

修改参数后点击「保存并应用」会自动重启服务使其生效（由 init.d 的 `reload_service` 配合完成）。

## 前置要求

* OpenWrt 25.12.2+
* 了解 OpenWrt 基本操作、终端使用，以及基本的 [mihomo 配置](https://wiki.metacubex.one/config/)

## 透明代理配置（TUN auto-redirect）

利用 mihomo 的 `auto-redirect` 特性：

```yaml
tun:
  enable: true
  stack: mixed
  dns-hijack:
    - "any:53"
  auto-route: true
  auto-redirect: true # 关键配置
  auto-detect-interface: true
```

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

## 下载

本仓库 CI 每 6 小时跟随上游最新 tag 自动构建 aarch64_generic / x86_64 的 APK，见 [Releases](https://github.com/hahaher123/openwrt-mihomo/releases)。上游原版构建产物见 [douglarek/vanilla-mihomo releases](https://github.com/douglarek/vanilla-mihomo/releases)。

安装示例（APK 会自动安装 kmod-tun、kmod-inet-diag、kmod-netlink-diag 等内核依赖）：

```
$ apk add mihomo-1.19.30-r1_aarch64_generic.apk --allow-untrusted
```
