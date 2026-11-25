# Experimental PT1570-R10 board profile for mainline rtw89 validation.
# Derived from upstream tianyi_tyfza1_2p5g (same rtk-taurus.dtsi platform).
# 2026-11-25: follow upstream rtw89 package split (299da19e2ea6).
define Device/youhua_pt1570_r10_rtw89_exp
  DEVICE_VENDOR := Youhua
  DEVICE_MODEL := PT1570-R10
  DEVICE_VARIANT := rtw89-exp
  SUPPORTED_DEVICES += youhua,pt1570-r10-rtw89-exp
  DEVICE_DTS := rtl9617c-pt1570-r10-rtw89
  DEVICE_PACKAGES := fitblk rtl9617c-pon-control luci-app-rtl9617c-pon luci-theme-argon \
	kmod-gpio-button-hotplug luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-mod-system \
	uhttpd uhttpd-mod-ubus iperf3 ethtool ip-full tc curl htop openssl-util mtr socat \
	conntrack-tools wpad-openssl hostapd-common iw wireless-tools \
	kmod-rtw89-pci kmod-rtw89-8852ce rtl8852ce-firmware rtl8852ce-ap-firmware \
	kmod-rtw89-8192xbe rtl8192xbe-ap-firmware
endef
TARGET_DEVICES += youhua_pt1570_r10_rtw89_exp
