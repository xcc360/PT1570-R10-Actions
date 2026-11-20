
define Device/youhua_pt1570_h10_cu
  DEVICE_VENDOR := Youhua
  DEVICE_MODEL := PT1570-H10-CU
  DEVICE_VARIANT := 1x2.5GE + 3xGE + WiFi6 (Unicom)
  SUPPORTED_DEVICES += youhua,pt1570-h10-cu
  DEVICE_DTS := rtl9617c-pt1570-h10-cu
  DEVICE_PACKAGES := fitblk rtl9617c-pon-control luci-app-rtl9617c-pon luci-theme-argon \
	kmod-rtl-ax-ap wpad-mbedtls wifi-scripts wireless-regdb \
	kmod-gpio-button-hotplug kmod-usb3 kmod-usb-storage kmod-usb-storage-uas \
	block-mount kmod-fs-vfat kmod-fs-ext4 kmod-nls-utf8 \
	luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-mod-system \
	uhttpd uhttpd-mod-ubus iperf3 ethtool ip-full tc curl htop openssl-util mtr socat \
	conntrack-tools
endef
TARGET_DEVICES += youhua_pt1570_h10_cu
