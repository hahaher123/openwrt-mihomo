# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2026 ImmortalWrt.org

include $(TOPDIR)/rules.mk

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Leo Douglas <douglarek@gmail.com>

LUCI_TITLE:=LuCI support for Mihomo
LUCI_DEPENDS:=+luci-base +mihomo
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
