#!/bin/sh
# R10 统一 UBI 方案：sysupgrade 系统内升级修复。
#
# 文件名用 zz- 前缀，保证 /sbin/sysupgrade 与 /lib/upgrade/stage2 的
# `include /lib/upgrade`（/lib/functions.sh: for file in $(ls $1/*.sh)）
# 按字母序 source 时本文件排在 nand.sh / platform.sh / tar.sh 之后，
# 这里的同名函数定义能覆盖上游实现。
#
# 根因（2026-11-14 真机实证，run31 系统内升级 run31 复现）：
#   R10 靠 FIT 子镜像块设备挂根：ubi0_1(fit) -> ubiblock0_1 -> fitblk
#   驱动创建 /dev/fit0，/dev/root 就是 fit0 上的 squashfs。真机
#   /sys/devices/platform/fitblk/lower_dev 明确指向
#   .../ubi0/ubi0_1/ubiblock0_1，即 fit0 持有 ubiblock0_1。
#   上游 platform.sh 的 platform_do_upgrade() 直接 nand_do_upgrade()，
#   绕过了 /lib/upgrade/fit.sh 的 fit_do_upgrade() —— 后者会先
#   `[ -e /dev/fit0 ] && fitblk /dev/fit0` 释放子镜像，再按 CI_METHOD=ubi
#   调 nand_do_upgrade()。
#   于是 nand_upgrade_prepare_ubi() 里：
#     * nand_remove_ubiblock() 的 `ubiblock -r /dev/ubi0_1` 因 fit0 仍
#       持有 lower_dev 而失败 -> `cannot remove ubiblock0_1` -> return 1；
#     * 即便跳过，`ubirmvol -N fit / -N rootfs_data` 也会 EBUSY 且被
#       `|| :` 吞掉，紧接着 `ubimkvol -N ...` 因同名卷仍在而 return 1；
#     * nand_do_upgrade_failed() 只 echo "sysupgrade failed" 后 reboot -f。
#   表现就是「升级页面重启了，但 FIT 卷与 rootfs_data 原封不动」——
#   无论是否勾选「保留配置」，用户配置（密码/PPPoE/SSID）都还在。
#   U-Boot 走 ubiformat 整盘重建卷表，不受挂载影响，所以只有它能刷进去。
#   另：stage2 的 switch_to_ramfs() 默认复制列表不含 fitblk，
#   RAMFS_COPY_BIN 也只有 'fw_printenv fw_setenv'，ramfs 里根本没有
#   /usr/sbin/fitblk，所以必须同时把它加入 RAMFS_COPY_BIN。
#
# 修复：
#   1. RAMFS_COPY_BIN 追加 fitblk（install_bin 会带动态库进 ramfs）；
#   2. platform_do_upgrade() 写卷前先释放 /dev/fit0 / /dev/fitrw，
#      再卸载 overlay / rootfs_data，最后才 nand_do_upgrade()；
#   3. nand_do_restore_config() 受 UPGRADE_BACKUP 限制，保证 -n 不恢复配置。

# stage2 开头 RAMFS_COPY_BIN= 置空，include /lib/upgrade 时 platform.sh
# 设为 'fw_printenv fw_setenv'，本文件按字母序最后 source，追加 fitblk。
# 用绝对路径：switch_to_ramfs() 的 `command -v "$binary"` 对含斜杠路径
# 直接返回自身，且不依赖 ramfs 里的 PATH；install_bin() 会通过 libs()
# 一并带进 /lib/ld-musl-aarch64.so.1 与 /lib/libgcc_s.so.1。
RAMFS_COPY_BIN="$RAMFS_COPY_BIN /usr/sbin/fitblk"

nand_do_restore_config() {
	[ -n "$UPGRADE_BACKUP" ] || return 0
	local conf_tar="/tmp/sysupgrade.tgz"
	[ -f "$conf_tar" ] || return 0
	nand_restore_config "$conf_tar"
}

platform_do_upgrade() {
	CI_KERNPART=fit
	CI_UBIPART=ubi_device

	# 不保留配置时，绝不允许任何残留备份被恢复。
	[ -n "$UPGRADE_BACKUP" ] || rm -f /tmp/sysupgrade.tgz

	# 先释放 FIT 子镜像块设备；否则 ubi0_1 卷被 fitblk 持有，写卷必失败。
	# 用绝对路径：stage2 的 ramfs PATH 不一定包含 /usr/sbin。
	[ -e /dev/fit0 ] && /usr/sbin/fitblk /dev/fit0
	[ -e /dev/fitrw ] && /usr/sbin/fitblk /dev/fitrw

	# 无条件先把 overlay / rootfs_data 的挂载卸干净，让 nand.sh 的
	# ubirmvol 能成功（无论本次是否保留配置都需要）。
	umount -l /overlay 2>/dev/null || :
	local ubidev datavol
	ubidev="$(nand_find_ubi "$CI_UBIPART")"
	if [ -n "$ubidev" ]; then
		datavol="$(nand_find_volume "$ubidev" rootfs_data)"
		[ -n "$datavol" ] && umount -l "/dev/$datavol" 2>/dev/null || :
	fi

	nand_do_upgrade "$1"
}
