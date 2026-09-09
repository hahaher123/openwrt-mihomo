# OpenWrt-Mihomo

A native build of [Mihomo](https://github.com/MetaCubeX/mihomo) for OpenWrt and its derivatives, plus a simple LuCI app, in a single repository.

## Repository layout

```
openwrt-mihomo/
├── mihomo/            # mihomo package (installed to /usr/bin/mihomo, /etc/init.d/mihomo, /etc/config/mihomo)
└── luci-app-mihomo/   # LuCI app: service status, start/stop, runtime options
```

## Prerequisites

* OpenWrt 25.12.2+

## Basic Requirements

To effectively use, you should have:

* Basic knowledge of OpenWrt
* Proficiency in using the OpenWrt terminal
* Familiarity with basic [Mihomo configuration](https://wiki.metacubex.one/en/config/)

## Configuration

Utilizes the `auto-redirect` feature introduced in Mihomo:

```yaml
tun:
  enable: true
  stack: mixed
  dns-hijack:
    - "any:53"
  auto-route: true
  auto-redirect: true # Key configuration
  auto-detect-interface: true
```

Before packaging this project, I explored some usage methods, which can be referenced [here](https://gist.github.com/douglarek/99fb8d7f30fac2a6d2e9a32a47296e30) . It might be helpful.

## Download

You can download the latest release [here](https://github.com/douglarek/vanilla-mihomo/releases). Don't worry about the release time, it will always be the latest.

## LuCI (optional)

The bundled `luci-app-mihomo` provides a web interface for viewing the service status, starting/stopping the service, and editing run-time options (config file path, work directory, listening interfaces, boot-enabled flag, etc.). It requires OpenWrt 21.02+ (client-side rendering) and works with OpenWrt 25.

Build both packages in the SDK:

```
./scripts/feeds update -a
./scripts/feeds install luci
cp -a mihomo luci-app-mihomo package/
make package/mihomo/compile package/luci-app-mihomo/compile V=s
```

#### Install

> [!IMPORTANT]
> Starting from November 2024, OpenWrt will use the apk package manager by default. Sorry, this project will only support building APK packages and will no longer support IPK.

```
$ apk add mihomo-1.19.30-r1_aarch64_generic.apk --allow-untrusted
```

The APK package manager will automatically install the corresponding kernel module dependencies.
