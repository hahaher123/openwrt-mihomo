# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2026 ImmortalWrt.org

include $(TOPDIR)/rules.mk

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Leo Douglas <douglarek@gmail.com>

PKG_VERSION:=1.0.1
PKG_RELEASE:=7

LUCI_TITLE:=LuCI support for Mihomo
# "+mihomo" is a hard dependency: building/installing luci-app-mihomo
# automatically compiles and installs the mihomo package first.
LUCI_DEPENDS:=+luci-base +mihomo
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
