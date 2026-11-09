# SPDX-License-Identifier: GPL-2.0-only
# 插入到 target/linux/rtl9617c/image/Makefile 的 $(eval $(call BuildImage)) 之前。
# 产物规则与 lyq1996 树里 tianyi_tyfza1_2p5g 一致：FIT + external-static-with-rootfs。
# 唯一区别是 profile / DTS / board_name（PT1570-R10 有自己的 compatible）。
# ⚠️ DTS 侧已从 2.5G 板改用 4GE 板定义（2026-11-09 真机 FDT 实证：4×GE）。

define Device/youhua_pt1570_r10
  DEVICE_VENDOR := Youhua
  DEVICE_MODEL := PT1570-R10
  DEVICE_VARIANT := FIT
  # image.mk 会把 profile 名的下划线转成逗号（youhua,pt1570,r10），
  # 与 DTS compatible 对不上，sysupgrade 会拒绝；必须显式追加正确值。
  SUPPORTED_DEVICES += youhua,pt1570-r10
  DEVICE_DTS := rtl9617c-pt1570-r10
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := fitblk kmod-rtl-ax-ap tyfza1-pon-control luci-app-tyfza1-pon \
	ubi-utils nand-utils iw wpad-mbedtls wifi-scripts wireless-regdb \
	kmod-gpio-button-hotplug kmod-usb3 kmod-usb-storage kmod-usb-storage-uas \
	block-mount kmod-fs-vfat kmod-fs-ext4 kmod-nls-utf8 \
	luci luci-ssl luci-proto-ppp luci-app-firewall uhttpd uhttpd-mod-ubus \
	firewall4 dnsmasq
  KERNEL := kernel-bin | gzip
  KERNEL_INITRAMFS := kernel-bin | gzip | \
	fit gzip $$(KDIR)/image-rtl9617c-pt1570-r10.dtb with-initrd | pad-to 128k
  KERNEL_INITRAMFS_SUFFIX := -recovery.itb
  FILESYSTEMS := squashfs
  IMAGES := sysupgrade.itb
  IMAGE/sysupgrade.itb := append-kernel | \
	fit gzip $$(KDIR)/image-rtl9617c-pt1570-r10.dtb external-static-with-rootfs | \
	pad-rootfs | append-metadata
endef
TARGET_DEVICES += youhua_pt1570_r10
