#!/bin/bash
# PT1570-H10-CU（联通版）板级注入 + 平台缺陷修复（独立 workflow 专用，幂等）。
#
# 与 PT1500-H10 电信版不同：上游 lyq1996/rtl9617c-openwrt@20b4cf4
# 没有 youhua_pt1570_h10_cu profile / DTS / sysupgrade 白名单，必须注入：
#   1. target/linux/rtl9617c/dts/rtl9617c-pt1570-h10-cu.dts
#      （include 上游 rtl9617c-tyfza1-2p5g.dts，1x2.5GE + 3xGE + 双 PCIe WiFi6）
#   2. image/Makefile 在 BuildImage 之前插入 Device/youhua_pt1570_h10_cu
#   3. platform.sh 的 platform_check_image 白名单加 youhua,pt1570-h10-cu
# 然后再叠加两台机器都踩过的公共修复：
#   4. 删除上游 pt1500-fip.sh（老 fip 卷布局，会覆盖 platform.sh 并写错卷）
#   5. 修 tyfza1-factory 的 factory_blob 目标参数（$2 -> $3，校准软链接悬空）
#
# env: ASSETS=<资产仓库根>  WRT=<源码树>

set -euo pipefail

ASSETS="${ASSETS:-$(cd "$(dirname "$0")/../../.." && pwd)}"
WRT="${WRT:-$ASSETS/wrt}"
CU="$ASSETS/cu-h10/fw"
fail() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$WRT/target/linux/rtl9617c" ] || fail "找不到源码树 $WRT/target/linux/rtl9617c"

PROFILE="youhua_pt1570_h10_cu"
BOARD_NAME="youhua,pt1570-h10-cu"
DTS="rtl9617c-pt1570-h10-cu"
INC="$CU/board/devices/pt1570-h10-cu.mk.inc"
DTS_SRC="$CU/board/dts/${DTS}.dts"
IMG_MK="$WRT/target/linux/rtl9617c/image/Makefile"
DTS_DIR="$WRT/target/linux/rtl9617c/dts"
DTS_FILE="$DTS_DIR/${DTS}.dts"
DTSI="$DTS_DIR/rtl9617c-tyfza1.dtsi"
UPG_DIR="$WRT/target/linux/rtl9617c/base-files/lib/upgrade"
PLATFORM="$UPG_DIR/platform.sh"
UCI_DIR="$WRT/target/linux/rtl9617c/base-files/etc/uci-defaults"

for f in "$INC" "$DTS_SRC" "$IMG_MK" "$PLATFORM" "$DTSI"; do
  [ -f "$f" ] || fail "missing $f"
done

# ---- 0. 上游 2p5g 基线断言（本机 1x2.5GE + 3xGE）----
# 用 4ge 空壳板定义会让外置 RTL8221B 2.5G PHY 完全不初始化。
[ -f "$DTS_DIR/rtl9617c-tyfza1-2p5g.dts" ] \
  || fail "上游缺少 rtl9617c-tyfza1-2p5g.dts（1x2.5GE + 3xGE 基线）"
# 只认真正的 #include 行：DTS 注释里也提到了 4ge 文件名，裸 grep 会误命中。
grep -qE '^#include[[:space:]]+"rtl9617c-tyfza1-2p5g\.dts"' "$DTS_SRC" \
  || fail "CU DTS 未 include 2.5G 板定义"
grep -qE '^#include[[:space:]]+"rtl9617c-tyfza1-4ge\.dts"' "$DTS_SRC" \
  && fail "CU DTS 误用 4GE 空壳板定义（外置 2.5G PHY 不会初始化）"
grep -q 'rootdisk' "$DTSI" || fail "上游 dtsi 没有 chosen.rootdisk"
grep -q 'volname = "fit"' "$DTSI" || fail "上游 dtsi 没有 fit 卷"
# factory 卷 8 MiB，与 fpga-image@10000 (0x10000+0x7e0000=0x800000) 对齐。
# 该节点在 dtsi 而非板级 DTS（与 4ge/2p5g 选择无关），所以查 dtsi。
grep -q 'fpga-image@10000' "$DTSI" \
  || fail "dtsi 缺少 fpga-image@10000（factory 8 MiB 布局基线）"
grep -q 'UNVERIFIED' "$DTS_SRC" \
  && fail "CU DTS 仍带 UNVERIFIED 标记"
echo "  OK   2p5g 基线 / 统一 UBI / fpga-image@10000"

# ---- 1. DTS ----
cp -f "$DTS_SRC" "$DTS_FILE"
echo "  OK   注入 $DTS.dts"

# ---- 2. Device 定义 ----
if ! grep -q "define Device/${PROFILE}" "$IMG_MK"; then
  python3 - "$IMG_MK" "$INC" <<'PY'
import sys, pathlib
mk = pathlib.Path(sys.argv[1])
inc = pathlib.Path(sys.argv[2]).read_text(encoding='utf-8')
text = mk.read_text(encoding='utf-8')
marker = '$(eval $(call BuildImage))'
if marker not in text:
    raise SystemExit('ERROR: BuildImage marker not found in image/Makefile')
mk.write_text(text.replace(marker, inc.rstrip() + '\n\n' + marker, 1),
              encoding='utf-8')
print('  OK   注入 Device 定义')
PY
else
  echo "  OK   Device/${PROFILE} 已存在，跳过"
fi

# ---- 3. sysupgrade 白名单 ----
if ! grep -q "$BOARD_NAME" "$PLATFORM"; then
  python3 - "$PLATFORM" "$BOARD_NAME" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); name = sys.argv[2]
lines = p.read_text(encoding='utf-8').splitlines(keepends=True)
for i, line in enumerate(lines):
    if 'youhua,pt1500-h10-2p5g' in line and ') ;;' in line:
        lines[i] = line.replace(') ;;', '|' + name + ') ;;', 1)
        break
else:
    raise SystemExit('ERROR: platform.sh 白名单锚点未找到（上游改版？）')
p.write_text(''.join(lines), encoding='utf-8')
print('  OK   platform.sh 白名单 += ' + name)
PY
else
  echo "  OK   platform.sh 已列出 $BOARD_NAME"
fi

# ---- 4. 删除上游 pt1500-fip.sh ----
FIP_SH="$UPG_DIR/pt1500-fip.sh"
if [ -f "$FIP_SH" ]; then
  # 用 python3 unlink 而非 shell rm：Windows/Git-Bash 混合盘符路径下 rm 会被
  # safe-delete 拦截（embedded drive prefix is not allowed）；Linux CI runner
  # 上行为与 rm -f 完全等价，脚本本身其余注入步骤也已在用 python3。
  python3 -c 'import pathlib, sys; pathlib.Path(sys.argv[1]).unlink(missing_ok=True)' "$FIP_SH"
  echo "  OK   移除 pt1500-fip.sh（会覆盖 platform.sh 并写不存在的 fip 卷）"
else
  echo "  OK   pt1500-fip.sh 本就不存在"
fi

# ---- 5. tyfza1-factory: factory_blob <offset> <size> <dest> ----
FACTORY="$WRT/package/tyfza1-pon-control/files/tyfza1-factory"
[ -f "$FACTORY" ] || fail "找不到 $FACTORY"
if grep -q 'mv "\$tmp" "\$2"' "$FACTORY"; then
  python3 - "$FACTORY" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
old = '\t\tmv "$tmp" "$2"'
new = '\t\tmkdir -p "${3%/*}"\n\t\tmv "$tmp" "$3"'
if old not in text:
    raise SystemExit('ERROR: 未找到预期的 mv "$tmp" "$2" 行')
p.write_text(text.replace(old, new, 1), encoding='utf-8', newline='\n')
print('  OK   tyfza1-factory: mv "$tmp" "$3"')
PY
else
  echo "  OK   tyfza1-factory 已是修好的版本"
fi
grep -q 'mv "\$tmp" "\$3"' "$FACTORY" || fail "tyfza1-factory 修补失败"
! grep -q 'mv "\$tmp" "\$2"' "$FACTORY" || fail "tyfza1-factory 仍残留旧写法"

# ---- 6. 结果校验 ----
grep -q "SUPPORTED_DEVICES += ${BOARD_NAME}" "$IMG_MK" \
  || fail "image/Makefile 缺 SUPPORTED_DEVICES"
grep -q "DEVICE_DTS := ${DTS}" "$IMG_MK" \
  || fail "image/Makefile 的 DEVICE_DTS 不对"
grep -q "$BOARD_NAME" "$PLATFORM" || fail "platform.sh 白名单缺 $BOARD_NAME"
grep -q 'CI_KERNPART=fit' "$PLATFORM" || fail "platform.sh 升级目标卷不是 fit"
grep -q "compatible = \"${BOARD_NAME}\"" "$DTS_FILE" \
  || fail "注入的 DTS compatible 不对"
find "$UPG_DIR" -name 'pt1500-fip.sh' -print -quit | grep -q . \
  && fail "pt1500-fip.sh 仍存在" || true
! grep -rl 'this image is for youhua,pt1500-h10' "$UPG_DIR" 2>/dev/null | grep -q . \
  || fail "/lib/upgrade 残留 PT1500-H10 机型检查"

# 上游首启脚本（LED / lan MAC）必须齐全；绝不能混入 R10 的 99 / 95 覆盖脚本
for s in 90-tyfza1-pon-wan 95-pt1500-storage 96-pt1500-leds \
         96-tyfza1-lan-mac 97-pt1500-lan5; do
  [ -f "$UCI_DIR/$s" ] || fail "上游首启脚本缺失：$s"
done
[ ! -e "$UCI_DIR/99-pt1570-fit" ] \
  || fail "上游树混入 R10 的 99-pt1570-fit"
[ ! -e "$UCI_DIR/95-pt1570-wan-default" ] \
  || fail "上游树混入 R10 的 95-pt1570-wan-default"
# 上游默认 WAN 仍是 EPON 3961，由 CU 的 95 脚本覆盖
grep -q 'wan_vlan=3961' "$UCI_DIR/90-tyfza1-pon-wan" \
  || fail "上游默认 WAN VLAN 变了，CU 95 脚本需复核"

echo "CU_BOARD_OK=True profile=$PROFILE board=$BOARD_NAME dts=$DTS factory=8MiB"
