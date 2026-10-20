include $(TOPDIR)/rules.mk

PKG_NAME:=hostupdater
PKG_VERSION:=1.1.0
PKG_RELEASE:=8

PKG_MAINTAINER:=Gxxkx <anjiejayjo@gmail.com>
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Host Updater
  DEPENDS:=+curl +ca-bundle +luci-base +luci-compat
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  A generic hosts subscription source manager for OpenWrt. Downloads arbitrary
  remote hosts files, keeps a last-known-good cache per source and publishes the
  merged result as a dnsmasq "addnhosts" file, leaving /etc/hosts untouched.
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/hostupdater
/etc/hostupdater/sources.conf
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/hostupdater $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/etc/config/hostupdater $(1)/etc/config/

	$(INSTALL_DIR) $(1)/etc/hostupdater
	$(INSTALL_DATA) ./files/etc/hostupdater/sources.conf $(1)/etc/hostupdater/

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/hostupdater $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/hostupdater $(1)/lib/upgrade/keep.d/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/luci/controller/hostupdater.lua $(1)/usr/lib/lua/luci/controller/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/admin/services
	$(INSTALL_DATA) ./luasrc/luci/view/admin/services/hostupdater.htm $(1)/usr/lib/lua/luci/view/admin/services/

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-hostupdater.json $(1)/usr/share/rpcd/acl.d/

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-hostupdater.json $(1)/usr/share/luci/menu.d/

	$(INSTALL_DIR) $(1)/usr/share/luci/applications.d
	$(INSTALL_DATA) ./files/usr/share/luci/applications.d/luci-app-hostupdater.json $(1)/usr/share/luci/applications.d/

	$(INSTALL_DIR) $(1)/usr/share/luci/icons
	$(INSTALL_DATA) ./files/usr/share/luci/icons/hostupdater.svg $(1)/usr/share/luci/icons/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/i18n/hostupdater.*.lmo $(1)/usr/lib/lua/luci/i18n/
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

mkdir -p /etc/hostupdater/backup /etc/hostupdater/cache
chmod 755 /usr/bin/hostupdater /etc/init.d/hostupdater 2>/dev/null
chmod 644 /etc/config/hostupdater /etc/hostupdater/sources.conf 2>/dev/null

# Migrate the legacy /etc/hosts rewrite mode and register addnhosts.
[ -x /usr/bin/hostupdater ] && /usr/bin/hostupdater migrate >/dev/null 2>&1

/etc/init.d/hostupdater enable
/etc/init.d/hostupdater start >/dev/null 2>&1

[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1
[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart >/dev/null 2>&1

exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/hostupdater stop >/dev/null 2>&1
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

case "$$1" in
	upgrade|failed-upgrade|abort-upgrade)
		exit 0
		;;
esac

/etc/init.d/hostupdater stop >/dev/null 2>&1
/etc/init.d/hostupdater disable >/dev/null 2>&1

# Remove addnhosts entries pointing into /etc/hostupdater, keep other entries.
PATHS=$$(uci -q show dhcp.@dnsmasq[0].addnhosts 2>/dev/null | sed -e 's/^[^=]*=//' | tr ' ' '\n' | tr -d "'\"")
if [ -n "$$PATHS" ]; then
	uci -q delete dhcp.@dnsmasq[0].addnhosts
	for p in $$PATHS; do
		case "$$p" in
			/etc/hostupdater/*) continue ;;
		esac
		[ -n "$$p" ] && uci add_list dhcp.@dnsmasq[0].addnhosts="$$p"
	done
	uci commit dhcp
	[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq reload >/dev/null 2>&1
fi

rm -rf /etc/hostupdater
rm -f /etc/config/hostupdater

[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1
[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart >/dev/null 2>&1

exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
