#!/bin/sh
# R10 统一 UBI 方案：sysupgrade「不保留配置」修复。
#
# 文件名用 zz- 前缀，保证 /sbin/sysupgrade 的 `include /lib/upgrade`
# （/lib/functions.sh: for file in $(ls $1/*.sh); do . $file; done）
# 按字母序 source 时本文件排在 nand.sh / platform.sh / tar.sh 之后，
# 这里的同名函数定义能覆盖上游实现。
#
# 2026-11-14 真机现象：系统内更新无论是否勾选「保留配置」，配置都会
# 保留；只有 U-Boot 刷入（ubiformat 整个 ubi_device 分区）才清空。
#
# 两个叠加原因：
#  1. nand_do_upgrade_success() 无条件调用 nand_do_restore_config()，
#     而它只判断 /tmp/sysupgrade.tgz 是否存在，不看 SAVE_CONFIG /
#     UPGRADE_BACKUP。stage2 的 switch_to_ramfs 会把旧 root 的 /tmp
#     整个 move 进 ramfs，任何残留备份都会被恢复到新建的 rootfs_data
#     卷，于是 `sysupgrade -n` 也可能把配置带回来。
#  2. stage2 切到 ramfs 后 /overlay（/dev/ubi0_2）的挂载可能仍残留。
#     nand_upgrade_prepare_ubi() 里 `ubirmvol ... -N rootfs_data` 的失败
#     被 `|| :` 吞掉，紧接着 `ubimkvol -N rootfs_data` 因同名卷已存在
#     而失败并返回 1 —— 升级实际失败、旧 overlay 原封不动，表现正是
#     「无法通过系统内更新升级 / 配置总是保留」。
#     U-Boot 刷入走 ubiformat 整盘重建卷表，不受挂载影响，所以是干净的。

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
