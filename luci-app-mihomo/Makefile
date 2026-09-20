# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2026 ImmortalWrt.org

include $(TOPDIR)/rules.mk

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Leo Douglas <douglarek@gmail.com>

PKG_VERSION:=1.0.3
PKG_RELEASE:=4

LUCI_TITLE:=LuCI support for Mihomo
# "+mihomo" is a hard dependency: building/installing luci-app-mihomo
# automatically compiles and installs the mihomo package first.
#
# "+curl" is for the remote profile fetch (import / 仅更新 / 定时更新):
#   - curl carries its own TLS backend and pulls the CA bundle it needs, so
#     HTTPS subscriptions work without choosing an ustream variant here
#     (libustream-openssl/-mbedtls/-wolfssl all install the same
#     /lib/libustream-ssl.so — depending on one of them would conflict with
#     whatever the user's system already has)
#   - config.sh still falls back to wget, then uclient-fetch, so a system
#     without curl keeps working for plain HTTP
LUCI_DEPENDS:=+luci-base +mihomo +curl
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
