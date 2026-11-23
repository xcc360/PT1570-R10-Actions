# Experimental PT1570-H10-CU board profile for mainline rtw89 validation.
# Derived from upstream tianyi_tyfza1_2p5g (same rtk-taurus.dtsi platform,
# 1x2.5GE + 3xGE). NO private rtl_ax_ap.ko / NE-FE glue.
define Device/youhua_pt1570_h10_cu_rtw89_exp
  DEVICE_VENDOR := Youhua
  DEVICE_MODEL := PT1570-H10-CU
  DEVICE_VARIANT := rtw89-exp
  SUPPORTED_DEVICES += youhua,pt1570-h10-cu-rtw89-exp
  DEVICE_DTS := rtl9617c-pt1570-h10-cu-rtw89
  DEVICE_PACKAGES := fitblk rtl9617c-pon-control luci-app-rtl9617c-pon luci-theme-argon \
	kmod-gpio-button-hotplug luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-mod-system \
	uhttpd uhttpd-mod-ubus iperf3 ethtool ip-full tc curl htop openssl-util mtr socat \
	conntrack-tools wpad-openssl hostapd-common iw wireless-tools
endef
TARGET_DEVICES += youhua_pt1570_h10_cu_rtw89_exp
