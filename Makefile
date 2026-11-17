include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-prio
PKG_VERSION:=1.0.0
PKG_RELEASE:=86

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=congge

LUCI_TITLE:=LuCI Device Priority (tc ETS)
LUCI_MAINTAINER:=congge
LUCI_DESCRIPTION:=Per-device network priority with nft marks and the ETS qdisc on the WAN and LAN paths. The shaper follows the link with a latency loop.
# NOTE: sch_tbf and sch_fq_codel live in kmod-sched-core, sch_ets lives in
# kmod-sched. There are no kmod-sched-tbf / kmod-sched-ets / kmod-sched-fq_codel
# packages, so depending on them would break the build and the install.
LUCI_DEPENDS:=+luci-base +luci-compat +nftables +tc-full +kmod-sched-core +kmod-sched
LUCI_PKGARCH:=all

# These three must be defined BEFORE luci.mk is included: luci.mk expands
# BuildPackage at include time, and package-pack.mk reads Package/x/conffiles,
# Package/x/postinst and Package/x/prerm immediately. Defining them afterwards
# would silently have no effect.
define Package/luci-app-prio/conffiles
/etc/config/prio
endef

define Package/luci-app-prio/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	chmod 755 /etc/init.d/prio 2>/dev/null
	/etc/init.d/prio enable >/dev/null 2>&1
	/etc/init.d/prio reload >/dev/null 2>&1 &
	# New menu entries and ACL files need a dispatcher reload to appear.
	rm -f /tmp/luci-indexcache* 2>/dev/null
	/etc/init.d/rpcd reload >/dev/null 2>&1
}
exit 0
endef

define Package/luci-app-prio/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/prio stop >/dev/null 2>&1
	/etc/init.d/prio disable >/dev/null 2>&1
}
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
