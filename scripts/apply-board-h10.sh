#!/bin/bash
# PT1500-H10 2.5G 板级注入（独立 workflow 专用，幂等）。
#
# 与 R10 的 apply-board.sh 不同：上游 lyq1996/rtl9617c-openwrt@20b4cf4
# 已经有完整的 youhua_pt1500_h10_2p5g profile、rtl9617c-pt1500-h10-2p5g.dts、
# platform.sh 白名单与 95/96/97-pt1500-* 首启脚本，**不注入任何 Device/DTS**。
# 本脚本只做三件事：
#   1. 编译期移除上游 pt1500-fip.sh（它按老 fip 卷布局写，且会覆盖 platform.sh）；
#   2. 修 tyfza1-factory 的 factory_blob 目标参数（机型无关的 PON 平台缺陷）；
#   3. 断言上游机型定义齐全，改版时提前失败而不是编出废固件。
#
# 不做的（避免把 R10 资产串进来）：
#   * 不注入 rtl9617c-pt1570-r10.dts / Device/youhua_pt1570_r10；
#   * 不往 platform.sh 追加 youhua,pt1570-r10；
#   * 不放宽 fitblk FIT 头上限：本机型与 R10 同为 external-static-with-rootfs，
#     FIT 头仅 4096 B，4 MiB 上限根本不会触发（R10 run14 未打补丁实测可启动），
#     少一个补丁少一个失败点；
#   * 不校验/注入任何 WiFi AP 固件：2.5G 版 DTS 明确无 PCIe 端点、无 WiFi。
#
# env: ASSETS=<资产目录>  WRT=<源码树>

set -euo pipefail

ASSETS="${ASSETS:-$(cd "$(dirname "$0")/.." && pwd)}"
WRT="${WRT:-$ASSETS/wrt}"
fail() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$WRT/target/linux/rtl9617c" ] || fail "找不到源码树 $WRT/target/linux/rtl9617c"

PROFILE="youhua_pt1500_h10_2p5g"
BOARD_NAME="youhua,pt1500-h10-2p5g"
DTS="rtl9617c-pt1500-h10-2p5g"
IMG_MK="$WRT/target/linux/rtl9617c/image/Makefile"
DTS_FILE="$WRT/target/linux/rtl9617c/dts/${DTS}.dts"
UPG_DIR="$WRT/target/linux/rtl9617c/base-files/lib/upgrade"
PLATFORM="$UPG_DIR/platform.sh"

# ---- 1. 移除上游 pt1500-fip.sh ----
# /sbin/sysupgrade 的 `include /lib/upgrade` 按文件名字母序 source：
#   common.sh ... platform.sh -> pt1500-fip.sh -> tar.sh
# pt1500-fip.sh 排在 platform.sh 之后，会整体覆盖 platform_check_image /
# platform_do_upgrade / platform_copy_config。它的白名单虽含
# youhua,pt1500-h10-2p5g（机型校验不会报错），但 platform_do_upgrade 写的是
# `fip` UBI 卷，而本机卷表只有 factory(8MiB static) / fit / rootfs_data，
# 没有 fip，系统内升级必然报 "no fip volume" 并失败。
# 统一 UBI 方案必须走 platform.sh 的 CI_KERNPART=fit + nand_do_upgrade，
# 再叠加 files-h10/lib/upgrade/zz-pt1570-sysupgrade.sh 的 fitblk 释放修复。
FIP_SH="$UPG_DIR/pt1500-fip.sh"
if [ -f "$FIP_SH" ]; then
  rm -f "$FIP_SH"
  echo "removed upstream pt1500-fip.sh (old fip volume layout, not applicable to FIT/UBI)"
else
  echo "upstream pt1500-fip.sh absent, nothing to remove"
fi

# ---- 2. tyfza1-factory: factory_blob 目标参数 ----
# 函数签名 factory_blob <offset> <size> <dest>，上游结尾写的是 mv "$tmp" "$2"，
# $2 是长度不是目标路径，导致 /lib/firmware 下校准软链接全部悬空。
# 这是 PON 平台公共缺陷，H10 也要修（BOSA/A2H 校准数据从 factory 卷导出）。
FACTORY="$WRT/package/tyfza1-pon-control/files/tyfza1-factory"
[ -f "$FACTORY" ] || fail "找不到 $FACTORY（上游目录结构变了？）"

if grep -q 'mv "\$tmp" "\$2"' "$FACTORY"; then
  python3 - "$FACTORY" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
old = '\t\tmv "$tmp" "$2"'
new = '\t\tmkdir -p "${3%/*}"\n\t\tmv "$tmp" "$3"'
if old not in text:
    raise SystemExit('ERROR: 未找到预期的 mv "$tmp" "$2" 行（缩进不符）')
p.write_text(text.replace(old, new, 1), encoding='utf-8', newline='\n')
print('patched tyfza1-factory: factory_blob -> mv "$tmp" "$3"')
PY
else
  echo "tyfza1-factory 已是修好的版本，跳过"
fi
grep -q 'mv "\$tmp" "\$3"' "$FACTORY" \
  || fail 'tyfza1-factory 修补失败：没有 mv "$tmp" "$3"'
! grep -q 'mv "\$tmp" "\$2"' "$FACTORY" \
  || fail 'tyfza1-factory 仍残留 mv "$tmp" "$2"'
grep -q 'factory_blob \$((0x4000)) 1024' "$FACTORY" \
  || fail 'factory_blob 调用点与预期不符（上游改动？）'

# ---- 3. 断言上游机型定义齐全 ----
grep -q "^define Device/${PROFILE}$" "$IMG_MK" \
  || fail "上游 image/Makefile 缺少 Device/${PROFILE}"
grep -q "SUPPORTED_DEVICES += ${BOARD_NAME}" "$IMG_MK" \
  || fail "上游 image/Makefile 缺少 SUPPORTED_DEVICES += ${BOARD_NAME}"
grep -q "DEVICE_DTS := ${DTS}" "$IMG_MK" \
  || fail "上游 image/Makefile 的 DEVICE_DTS 不是 ${DTS}"
[ -f "$DTS_FILE" ] || fail "上游 DTS 缺失：$DTS_FILE"
grep -q 'compatible = "youhua,pt1500-h10-2p5g"' "$DTS_FILE" \
  || fail "上游 DTS 的 compatible 与 $BOARD_NAME 不一致"
grep -q "${BOARD_NAME}" "$PLATFORM" \
  || fail "platform.sh 白名单缺少 ${BOARD_NAME}"
grep -q 'CI_KERNPART=fit' "$PLATFORM" \
  || fail "platform.sh 升级目标卷不是 fit"
grep -q 'volname = "fit"' "$DTS_FILE" \
  || fail "DTS 缺少 volname=fit 的 UBI 卷"
# factory 卷 8 MiB，与 DTS 的 fpga-image@10000 (0x10000+0x7e0000=0x800000) 对齐
grep -q 'fpga-image@10000' "$DTS_FILE" \
  || fail "DTS 缺少 fpga-image@10000（factory 8 MiB 布局基线）"

# 上游首启脚本必须存在（LED / lan5(2.5G) / lan MAC 由它们处理，不能用 R10 的 99-pt1570-fit）
UCI_DIR="$WRT/target/linux/rtl9617c/base-files/etc/uci-defaults"
for s in 95-pt1500-storage 96-pt1500-leds 96-tyfza1-lan-mac 97-pt1500-lan5; do
  [ -f "$UCI_DIR/$s" ] || fail "上游首启脚本缺失：$s"
done

# 结果：绝不能残留 fip 覆盖脚本
find "$UPG_DIR" -name 'pt1500-fip.sh' -print -quit | grep -q . \
  && fail "pt1500-fip.sh 仍存在，会覆盖 sysupgrade 并写不存在的 fip 卷" || true

echo "H10_BOARD_OK=True profile=$PROFILE board=$BOARD_NAME dts=$DTS"
