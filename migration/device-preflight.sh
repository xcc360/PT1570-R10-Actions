#!/bin/sh
# 设备侧「只读」前置检查：在当前还能启动的旧系统上跑，把迁移所需信息导出到 stdout。
# 不写 flash、不改 env、不重启、不删卷。请把输出完整保存成文本文件。
#
#   sh device-preflight.sh > pt1570-preflight.txt 2>&1
#
# 迁移到 统一 UBI 方案 前必须拿到这些东西，否则一旦重建 UBI 就无法回退。

echo "===== PT1570 FIT migration preflight (READ ONLY) ====="
echo "date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null)"
echo "kernel=$(uname -a)"
echo "board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo unknown)"
echo "model=$(cat /tmp/sysinfo/model 2>/dev/null || echo unknown)"

echo "----- mtd partitions -----"
cat /proc/mtd 2>/dev/null || echo "no /proc/mtd"

echo "----- UBI volumes (ubinfo -a) -----"
if command -v ubinfo >/dev/null 2>&1; then
  ubinfo -a 2>&1 || true
else
  echo "ubinfo not available"
fi

echo "----- current root / overlay -----"
mount 2>/dev/null | grep -E 'ubi|overlay|rootfs' || true
df -h / /overlay /rom 2>/dev/null || true

echo "----- U-Boot env (READ ONLY, full export) -----"
if command -v fw_printenv >/dev/null 2>&1; then
  fw_printenv 2>&1 || true
else
  echo "fw_printenv not available; dump mtd1/mtd2 from the tool instead"
fi
echo "bootcmd=$(fw_printenv -n bootcmd 2>/dev/null || echo unknown)"

echo "----- factory / identity data -----"
for f in /etc/tyfza1-factory/* /tmp/tyfza1-factory/*; do
  [ -f "$f" ] && echo "  $f $(wc -c < "$f") bytes"
done
echo "NOTE: factory bin is DEVICE-SPECIFIC. Never copy it to another unit."

echo "----- network / PHY / GPIO facts for DTS porting -----"
ip -br link 2>/dev/null || true
ls /sys/class/net 2>/dev/null || true
dmesg 2>/dev/null | grep -iE 'phy|rtl8211|rtl8221|pcie|pon|xgpon' | tail -60 || true

echo "----- existing local fixes that a clean squashfs will LOSE -----"
for f in \
  /overlay/upper/etc/init.d/wifi-guard \
  /overlay/upper/etc/rc.local \
  /etc/init.d/wifi-guard \
  /etc/uhttpd.crt /etc/uhttpd.key \
  /etc/nftables.d/*.nft ; do
  [ -e "$f" ] && echo "  PRESENT $f"
done
echo "  (overlay symlink, static EC cert, wifi-guard, boot speedups, tailscale cleanup tweaks)"

echo "===== END (no changes were made) ====="
