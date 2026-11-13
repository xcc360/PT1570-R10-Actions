#!/bin/bash
# 把「新增机型支持」注入 lyq1996/rtl9617c-openwrt 源码树（只改 3 处，幂等）。
#
#   env PT1570_BOARD = r10（当前唯一支持的机型）
#   env ASSETS       = 本资产目录（含 board/ scripts/）
#   env WRT          = 源码树路径
#   env DTS_STATUS   = experimental | verified
#   env PT1570_ALLOW_H10 = 1 时才允许处理 h10（DORMANT，默认拒绝）
#
# 2026-11-09：按用户决定收窄为 R10-only。H10 资产保留但不参与构建，
# 且 H10 DTS 没有真机数据支撑，默认必须拒绝，避免误产出不可刷固件。
#
# 注入点：
#   1. target/linux/rtl9617c/dts/<DTS>.dts          新增板级 DTS
#   2. target/linux/rtl9617c/image/Makefile         在 BuildImage 之前插入 Device 定义
#   3. target/linux/rtl9617c/base-files/lib/upgrade/platform.sh
#                                                    platform_check_image 白名单加 board_name
# 不改 board.d/02_network：LAN 接线由 files/etc/uci-defaults/99-pt1570-fit 兜底。

set -euo pipefail

BOARD="${PT1570_BOARD:-}"
ASSETS="${ASSETS:-$(cd "$(dirname "$0")/.." && pwd)}"
WRT="${WRT:-$ASSETS/wrt}"
STATUS="${DTS_STATUS:-experimental}"

case "$BOARD" in
  r10) PROFILE="youhua_pt1570_r10"; DTS="rtl9617c-pt1570-r10"; BOARD_NAME="youhua,pt1570-r10" ;;
  h10)
    if [ "${PT1570_ALLOW_H10:-0}" != "1" ]; then
      echo "ERROR: PT1570-H10 已暂缓（DORMANT），当前范围是 R10-only。" >&2
      echo "       该机型的 DTS 没有真机数据支撑，禁止产出固件。" >&2
      echo "       确需恢复双机型：先完成 H10 真机采集，再设 PT1570_ALLOW_H10=1。" >&2
      exit 1
    fi
    PROFILE="youhua_pt1570_h10"; DTS="rtl9617c-pt1570-h10"; BOARD_NAME="youhua,pt1570-h10" ;;
  *) echo "ERROR: PT1570_BOARD must be r10 (R10-only scope)" >&2; exit 1 ;;
esac

INC="$ASSETS/board/devices/pt1570-${BOARD}.mk.inc"
DTS_SRC="$ASSETS/board/dts/${DTS}.dts"
IMG_MK="$WRT/target/linux/rtl9617c/image/Makefile"
PLATFORM="$WRT/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh"

for f in "$INC" "$DTS_SRC" "$IMG_MK" "$PLATFORM"; do
  test -f "$f" || { echo "ERROR: missing $f" >&2; exit 1; }
done

# ---- 1. DTS ----
cp -v "$DTS_SRC" "$WRT/target/linux/rtl9617c/dts/${DTS}.dts"
if [ "$STATUS" = "verified" ]; then
  if grep -q 'UNVERIFIED' "$WRT/target/linux/rtl9617c/dts/${DTS}.dts"; then
    echo "ERROR: DTS_STATUS=verified 但 DTS 仍带 UNVERIFIED 标记；请先完成真机核对" >&2
    exit 1
  fi
fi

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
text = text.replace(marker, inc.rstrip() + '\n\n' + marker, 1)
mk.write_text(text, encoding='utf-8')
print('injected Device definition before BuildImage')
PY
else
  echo "Device/${PROFILE} already present, skip"
fi

# ---- 3. sysupgrade 白名单 ----
if ! grep -q "$BOARD_NAME" "$PLATFORM"; then
  python3 - "$PLATFORM" "$BOARD_NAME" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
name = sys.argv[2]
lines = p.read_text(encoding='utf-8').splitlines(keepends=True)
for i, line in enumerate(lines):
    # 不能写死 "pt1500-h10-2p5g) ;;"：第一个机型注入后该串就消失了，
    # 同一源码树再注入第二个机型会失败。按「含锚点 + 以 ) ;; 收尾」定位。
    if 'youhua,pt1500-h10-2p5g' in line and ') ;;' in line:
        lines[i] = line.replace(') ;;', '|' + name + ') ;;', 1)
        break
else:
    raise SystemExit('ERROR: platform.sh whitelist line not found; check upstream layout')
p.write_text(''.join(lines), encoding='utf-8')
print('platform_check_image whitelist extended with ' + name)
PY
else
  echo "platform.sh already lists $BOARD_NAME, skip"
fi

# ---- 4. 移除上游 PT1500-H10 的 FIP 升级脚本（2026-11-14 真机实证） ----
# 上游 feature/pt1500-h10-openwrt-fixes 分支带
#   target/linux/rtl9617c/base-files/lib/upgrade/pt1500-fip.sh
# 它自定义 platform_check_image() / platform_do_upgrade() / platform_copy_config()，
# 而 /sbin/sysupgrade 的 `include /lib/upgrade` 按文件名字母序 source 全部 *.sh：
#   common.sh ... platform.sh → pt1500-fip.sh → tar.sh
# pt1500-fip.sh 排在 platform.sh 之后，会整体覆盖第 3 节注入的 R10 白名单实现。
# 真机（run28）实测报错：
#   "this image is for youhua,pt1500-h10, not youhua,pt1570-r10" / Image check failed.
# 更危险的是它的 platform_do_upgrade 会写 `fip` UBI 卷（PT1500-H10 老布局），
# 而 R10 统一 UBI 方案只有 factory / fit / rootfs_data 三卷；强行 sysupgrade -F
# 会写错分区。R10 必须走 platform.sh 的 CI_KERNPART=fit + nand_do_upgrade。
# 编译期根除该文件即可（workflow 后面有 make package/base-files/clean 重编）。
UPG_DIR="$WRT/target/linux/rtl9617c/base-files/lib/upgrade"
FIP_SH="$UPG_DIR/pt1500-fip.sh"
if [ -f "$FIP_SH" ]; then
  rm -f "$FIP_SH"
  echo "removed upstream pt1500-fip.sh (PT1500-H10 FIP layout, not applicable to R10)"
else
  echo "upstream pt1500-fip.sh absent, nothing to remove"
fi

# ---- 结果校验 ----
grep -q "SUPPORTED_DEVICES += ${BOARD_NAME}" "$IMG_MK" \
  || { echo "ERROR: SUPPORTED_DEVICES missing" >&2; exit 1; }
grep -q "$BOARD_NAME" "$PLATFORM" \
  || { echo "ERROR: platform.sh whitelist missing" >&2; exit 1; }
# 升级实现必须是 R10 统一 UBI 的 fit 卷，且不能残留 PT1500-H10 的 FIP 覆盖脚本：
# include /lib/upgrade 按字母序 source，pt1500-fip.sh 会盖掉 platform.sh。
find "$UPG_DIR" -name 'pt1500-fip.sh' -print -quit | grep -q . \
  && { echo "ERROR: pt1500-fip.sh 仍存在，会覆盖 R10 的 sysupgrade 机型校验并写错 fip 卷" >&2; exit 1; }
! grep -rl 'this image is for youhua,pt1500-h10' "$UPG_DIR" 2>/dev/null | grep -q . \
  || { echo "ERROR: /lib/upgrade 仍残留 PT1500-H10 机型检查" >&2; exit 1; }
grep -q 'CI_KERNPART=fit' "$PLATFORM" \
  || { echo "ERROR: platform.sh 未把升级目标卷设为 fit（统一 UBI 方案）" >&2; exit 1; }
grep -q 'rootdisk' "$WRT/target/linux/rtl9617c/dts/rtl9617c-tyfza1.dtsi" \
  || { echo "ERROR: 上游 dtsi 没有 chosen.rootdisk，统一 UBI 方案不成立" >&2; exit 1; }
grep -q 'volname = "fit"' "$WRT/target/linux/rtl9617c/dts/rtl9617c-tyfza1.dtsi" \
  || { echo "ERROR: 上游 dtsi 没有 fit 卷" >&2; exit 1; }

# R10 真机是 4×GE，DTS 必须基于上游 4GE 板定义；上游改名时提前失败而不是等到编译。
if [ "$BOARD" = "r10" ]; then
  DTS_DIR="$WRT/target/linux/rtl9617c/dts"
  test -f "$DTS_DIR/rtl9617c-tyfza1-4ge.dts" \
    || { echo "ERROR: 上游缺少 rtl9617c-tyfza1-4ge.dts（R10 的 4×GE 基线）" >&2; exit 1; }
  grep -q 'rtl9617c-tyfza1-4ge.dts' "$DTS_DIR/$DTS.dts" \
    || { echo "ERROR: R10 DTS 未 include 4GE 板定义" >&2; exit 1; }
  ! grep -q 'rtl9617c-tyfza1-2p5g.dts' "$DTS_DIR/$DTS.dts" \
    || { echo "ERROR: R10 DTS 误用 2.5G 板定义，4×GE 会不通" >&2; exit 1; }
  echo "R10 4GE baseline OK"
fi

echo "apply-board OK: board=$BOARD profile=$PROFILE dts=$DTS status=$STATUS"
