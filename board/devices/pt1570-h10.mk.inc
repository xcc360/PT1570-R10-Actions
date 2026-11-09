# SPDX-License-Identifier: GPL-2.0-only
#
# ⛔ DORMANT / 2026-11-09 起 H10 暂缓：本文件不参与任何构建（R10-only）。
#    恢复条件见 PT1570-R10-单机型验证报告 / 方案文档。
#
# 插入到 target/linux/rtl9617c/image/Makefile 的 $(eval $(call BuildImage)) 之前。
# PT1570-H10 无 WiFi / 无 PCIe endpoint（据 U-Boot 板级文档为四 GE 纯有线），
# 因此不列 kmod-rtl-ax-ap / wpad / wifi-scripts。

define Device/youhua_pt1570_h10
  DEVICE_VENDOR := Youhua
  DEVICE_MODEL := PT1570-H10
  DEVICE_VARIANT := FIT (4xGE)
  SUPPORTED_DEVICES += youhua,pt1570-h10
  DEVICE_DTS := rtl9617c-pt1570-h10
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := fitblk tyfza1-pon-control luci-app-tyfza1-pon \
	ubi-utils nand-utils kmod-usb3 block-mount kmod-fs-ext4 kmod-nls-utf8 \
	kmod-gpio-button-hotplug \
	luci luci-ssl luci-proto-ppp luci-app-firewall uhttpd uhttpd-mod-ubus \
	firewall4 dnsmasq
  KERNEL := kernel-bin | gzip
  KERNEL_INITRAMFS := kernel-bin | gzip | \
	fit gzip $$(KDIR)/image-rtl9617c-pt1570-h10.dtb with-initrd | pad-to 128k
  KERNEL_INITRAMFS_SUFFIX := -recovery.itb
  FILESYSTEMS := squashfs
  IMAGES := sysupgrade.itb
  IMAGE/sysupgrade.itb := append-kernel | \
	fit gzip $$(KDIR)/image-rtl9617c-pt1570-h10.dtb external-static-with-rootfs | \
	pad-rootfs | append-metadata
endef
TARGET_DEVICES += youhua_pt1570_h10
