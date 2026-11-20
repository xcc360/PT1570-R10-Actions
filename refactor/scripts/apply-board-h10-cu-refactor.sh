#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# PT1570-H10-CU（联通版）refactor 基线板级注入（幂等，编译期执行）。
#
# 职责：
#   1. 校验 refactor 基线（2.5G HisGMII/SerDes、rtl9617c-pon-control 在；base 特征不在）
#   2. 注入 CU 板级 DTS（rtl9617c-pt1570-h10-cu.dts，自建 PCIe + 12 灯 + cal）
#   3. 注入 Device 定义（image/Makefile）
#   4. platform.sh 白名单加 youhua,pt1570-h10-cu（check_image + do_upgrade）
#   5. 调 overlay-wifi-pcie.sh 回移植 PCIe/WiFi 驱动 + 内核 config 符号
#   6. config/pon 的 mode 纠正为 xgpon（本机 XGPON 线路）
#
# 遵循上游/OpenWrt 规范：DTS 放 target/linux/rtl9617c/dts/，Device 放 image/Makefile，
# 驱动放 files-6.18/drivers/，包用 rtl9617c-* / kmod-rtl-ax-ap，摒弃 tyfza1-* 私有命名。
#
# env: ASSETS=<资产仓库根>  WRT=<源码树>（默认 $ASSETS/wrt）
set -euo pipefail

ASSETS="${ASSETS:-$(cd "$(dirname "$0")/../.." && pwd)}"
WRT="${WRT:-$ASSETS/wrt}"
REF="$ASSETS/refactor"
fail() { echo "ERROR: $*" >&2; exit 1; }

TGT="$WRT/target/linux/rtl9617c"
[ -d "$TGT" ] || fail "找不到源码树 $TGT"

PROFILE="youhua_pt1570_h10_cu"
BOARD_NAME="youhua,pt1570-h10-cu"
DTS="rtl9617c-pt1570-h10-cu"

# ---- 0. refactor 基线断言（防止 source_ref 串回 base）----
[ -f "$TGT/dts/rtl9617c.dtsi" ] || fail "缺 refactor rtl9617c.dtsi（source_ref 串回 base？）"
[ -f "$TGT/files-6.18/drivers/net/phy/realtek/realtek_hisgmii.c" ] \
  || fail "缺 refactor HisGMII 2.5G 驱动"
[ -f "$TGT/files-6.18/drivers/phy/realtek/phy-rtl9617c-serdes.c" ] \
  || fail "缺 refactor SerDes 2.5G 驱动"
[ -d "$WRT/package/rtl9617c/rtl9617c-pon-control" ] \
  || fail "缺 rtl9617c-pon-control 包（refactor 规范包名）"
[ -f "$TGT/dts/rtl9617c-tyfza1.dtsi" ] \
  && fail "检测到 base tyfza1.dtsi（refactor 基线不应有，source_ref 串了？）" || true
echo "  OK   refactor 基线（HisGMII/SerDes + rtl9617c-pon-control，无 tyfza1 base 残留）"

# ---- 1. 注入 CU DTS ----
DTS_SRC="$REF/dts/${DTS}.dts"
DTS_DST="$TGT/dts/${DTS}.dts"
[ -f "$DTS_SRC" ] || fail "缺 CU DTS 资产 $DTS_SRC"
# 结构断言：2.5G + PCIe + 12 灯 + factory nvmem + 无 base 特征
for kw in 'realtek,hisgmii' 'realtek,serdes-option-mode' 'phy-mode = "2500base-x"' \
          'phys = <&serdes>' 'pcie_controls:' 'pcie0:' 'pcie1:' \
          'ubi-volume-factory' 'wifi-calibration@2000' 'wifi-calibration@3000' \
          'rootdisk = <&ubi_rootdisk>'; do
  grep -qF "$kw" "$DTS_SRC" || fail "CU DTS 缺关键项：$kw"
done
# 只检查有效代码（剥离 // 注释行），否则注释里"摒弃 realtek,hsgmii"会误命中
python3 - "$DTS_SRC" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1])
code = '\n'.join(re.sub(r'//.*$', '', ln) for ln in p.read_text(encoding='utf-8').splitlines())
for kw in ['realtek,hsgmii', 'p6-bringup-off', '#include "rtl9617c-tyfza1', '&ni0']:
    if kw in code:
        raise SystemExit('ERROR: CU DTS 有效代码残留 base 特征：%s' % kw)
print('  OK   CU DTS 有效代码无 base 特征')
PY
cp -f "$DTS_SRC" "$DTS_DST"
echo "  OK   注入 CU DTS（2.5G + PCIe + 12 灯 + factory nvmem）"

# ---- 2. 注入 Device 定义 ----
IMG_MK="$TGT/image/Makefile"
INC="$REF/scripts/device-pt1570-h10-cu.mk.inc"
[ -f "$IMG_MK" ] && [ -f "$INC" ] || fail "缺 image/Makefile 或 Device inc"
if ! grep -q "define Device/${PROFILE}" "$IMG_MK"; then
  python3 - "$IMG_MK" "$INC" <<'PY'
import sys, pathlib
mk = pathlib.Path(sys.argv[1])
inc = pathlib.Path(sys.argv[2]).read_text(encoding='utf-8')
text = mk.read_text(encoding='utf-8')
marker = '$(eval $(call BuildImage))'
if marker not in text:
    raise SystemExit('ERROR: image/Makefile 缺 BuildImage marker')
mk.write_text(text.replace(marker, inc.rstrip() + '\n\n' + marker, 1), encoding='utf-8')
print('  OK   注入 Device 定义')
PY
else
  echo "  OK   Device/${PROFILE} 已存在"
fi
grep -q "SUPPORTED_DEVICES += ${BOARD_NAME}" "$IMG_MK" || fail "image/Makefile 缺 SUPPORTED_DEVICES"
grep -q "DEVICE_DTS := ${DTS}" "$IMG_MK" || fail "image/Makefile 的 DEVICE_DTS 不对"

# ---- 3. platform.sh 白名单（check_image + do_upgrade 两处 case）----
PLATFORM="$TGT/base-files/lib/upgrade/platform.sh"
[ -f "$PLATFORM" ] || fail "缺 platform.sh"
if ! grep -q "$BOARD_NAME" "$PLATFORM"; then
  python3 - "$PLATFORM" "$BOARD_NAME" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); name = sys.argv[2]
lines = p.read_text(encoding='utf-8').splitlines(keepends=True)
anchored = 0
for i, line in enumerate(lines):
    if 'youhua,pt1500-h10-2p5g)' in line:
        lines[i] = line.replace('youhua,pt1500-h10-2p5g)',
                                'youhua,pt1500-h10-2p5g|' + name + ')', 1)
        anchored += 1
if anchored != 2:
    raise SystemExit('ERROR: platform.sh 白名单锚点数 %d != 2（上游改版？）' % anchored)
p.write_text(''.join(lines), encoding='utf-8')
print('  OK   platform.sh 白名单 += ' + name + ' (check + upgrade)')
PY
else
  echo "  OK   platform.sh 已列 $BOARD_NAME"
fi
grep -q "$BOARD_NAME" "$PLATFORM" || fail "platform.sh 白名单注入失败"
grep -q 'fit_do_upgrade' "$PLATFORM" || fail "platform.sh 未走 fit_do_upgrade（refactor 特征）"

# ---- 4. PON mode 纠正为 xgpon（本机 XGPON 线路）----
PON_CFG="$WRT/package/rtl9617c/rtl9617c-pon-control/files/etc/config/pon"
[ -f "$PON_CFG" ] || fail "缺 config/pon"
python3 - "$PON_CFG" <<'PY'
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]); t = p.read_text(encoding='utf-8')
t2 = re.sub(r"option mode '[^']*'", "option mode 'xgpon'", t, count=1)
if "option mode 'xgpon'" not in t2:
    raise SystemExit('ERROR: config/pon mode 未能纠正为 xgpon')
p.write_text(t2, encoding='utf-8')
print('  OK   config/pon mode -> xgpon')
PY

# ---- 5. 回移植 PCIe/WiFi 驱动（含内核 config 符号）----
bash "$REF/../scripts/refactor/overlay-wifi-pcie.sh" || fail "overlay-wifi-pcie.sh 失败"

# ---- 6. 结果校验 ----
echo "CU_REFACTOR_BOARD_OK=True profile=$PROFILE board=$BOARD_NAME dts=$DTS"
