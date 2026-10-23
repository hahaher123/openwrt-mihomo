# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2023 ImmortalWrt.org

include $(TOPDIR)/rules.mk

PKG_NAME:=mihomo
PKG_VERSION:=1.19.33
PKG_RELEASE:=3

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/MetaCubeX/mihomo/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=skip

PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Leo Douglas <douglarek@gmail.com>

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/metacubex/mihomo
GO_PKG_BUILD_PKG:=$(GO_PKG)
GO_PKG_LDFLAGS_X:= \
        $(GO_PKG)/constant.Version=v$(PKG_VERSION) \
        $(GO_PKG)/constant.BuildTime=$(shell date "+%F-%T-%Z")
GO_PKG_TAGS:=with_gvisor

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

# Bundled Country.mmdb (released to /etc/mihomo on install).
# HASH:=skip on purpose: this branch file is updated upstream over time,
# a pinned hash would break future builds. Verified against the jsdelivr CDN.
#
# geoip.dat / geosite.dat are deliberately NOT shipped any more:
#   * geodata-mode: false (the recommended setting) makes mihomo read
#     Country.mmdb for GEOIP rules, so the two .dat files are never opened;
#   * the shared copies live in /usr/share/v2ray and are maintained by
#     oxidns (its download plugin refreshes them on a schedule), so this
#     package must not own or overwrite them.
# Keep mihomo on the mmdb side only; see README "Country.mmdb".
define Download/country-mmdb
  FILE:=Country.mmdb
  URL:=https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release
  URL_FILE:=Country.mmdb
  HASH:=skip
endef

$(eval $(call Download,country-mmdb))

define Package/mihomo
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=A rule-based tunnel in Go
  URL:=https://github.com/MetaCubeX/mihomo
  # /usr/share/v2ray/{geoip.dat,geosite.dat} 不再由 v2ray-geoip / v2ray-geosite
  # 提供：整机镜像里它们是 FILES 覆盖层的一部分（构建时从 Loyalsoldier 下载），
  # 由 oxidns 负责刷新，本包只通过软链接消费（见 Package/mihomo/install）。
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle +kmod-tun +kmod-inet-diag +kmod-netlink-diag
endef

define Package/mihomo/description
  Mihomo is a cross-platform rule-based proxy utility that runs on the
  network and application layer, supporting various proxy and
  anti-censorship protocols out-of-the-box.

  It has been adopted widely by the Internet users in some countries
  and regions where the Internet is heavily censored or blocked.
  Either way, Mihomo can be used by anyone who wants to improve their
  Internet experience.
endef

define Package/mihomo/conffiles
/etc/mihomo/config.yaml
/etc/config/mihomo
endef

define Package/mihomo/install
	$(call GoPackage/Package/Install/Bin,$(1))

	$(INSTALL_DIR) $(1)/etc/mihomo/
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/docs/config.yaml $(1)/etc/mihomo/example.yaml
	# tproxy.sh 与 clash.nft 由 luci-app-mihomo 安装（随其 root/ 目录释放），
	# mihomo.init 对两者都做了 [ -f ] 守卫，单独安装 mihomo 包时透明代理
	# 相关的加载步骤会自动跳过。

	$(INSTALL_DATA) $(DL_DIR)/Country.mmdb $(1)/etc/mihomo/Country.mmdb

	# geoip.dat / geosite.dat 不再随包发布（见文件头的 Download/country-mmdb 注释），
	# 装的是指向共享库的软链接：/usr/share/v2ray/ 由整机镜像的 FILES 覆盖层提供
	# （构建时从 Loyalsoldier 下载），内容与刷新由 oxidns 负责（mihomo 不参与更新）。
	# mihomo 读 dat 的路径写死在 workdir 里、没有配置项，所以只能用链接把
	# 「/etc/mihomo/geoip.dat」这个名字定位过去。geodata-mode: false（默认）时
	# 这两个名字根本不会被打开，链接悬空也不影响启动。
	$(LN) /usr/share/v2ray/geoip.dat $(1)/etc/mihomo/geoip.dat
	$(LN) /usr/share/v2ray/geosite.dat $(1)/etc/mihomo/geosite.dat

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/mihomo.config $(1)/etc/config/mihomo

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/mihomo.init $(1)/etc/init.d/mihomo
endef

$(eval $(call GoBinPackage,mihomo))
$(eval $(call BuildPackage,mihomo))
