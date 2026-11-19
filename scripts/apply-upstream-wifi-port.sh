#!/bin/bash
# PT1570-R10 WiFi：在「已验证的单 PE1 参考驱动」上，定向移植上游 0.8.4 的
# 扫描/站点 RSSI 上报修复（LeoooChen/PonWRT-TYFZA1@6077a9a76812 的 single-PE
# 兼容子集），以及 0.8.5 的 RA 信号解析结构（@f74af178efe5 的 rate.h 子集）。
#
# 边界（违反任一条即 fail，绝不产出可刷固件）：
#   - 只在 overlay-wifi-driver.sh 之后执行：锚点是我们的参考版驱动，不是上游现场版。
#   - 禁止引入双 PE：pe-core.c 不存在、Makefile 无 pe-core.o、无 rx-geometry WD 保留位。
#   - pe-tx-code.h 必须是 4076-word / md5=7eb49893 的单 PE1 微码，绝不替换。
#   - 不整包覆盖 pe-tx-code.h / monitor.h / pci.c；只按唯一锚点做最小插入。
#   - 幂等：检测标记存在即跳过，重复执行不重复打补丁。
#   - WIFI_PORT=off 时本脚本直接退出，构建行为与现网完全一致。
#
# 用法：WIFI_PORT=scan-rssi|scan-rssi+ra ASSETS=<workspace> WRT=<workspace>/wrt \
#       bash apply-upstream-wifi-port.sh
set -euo pipefail

ASSETS="${ASSETS:-$GITHUB_WORKSPACE}"
WRT="${WRT:-$ASSETS/wrt}"
WIFI_PORT="${WIFI_PORT:-off}"

fail() { echo "::error::WIFI_PORT: $*" >&2; exit 1; }

case "$WIFI_PORT" in
  off) echo "WIFI_PORT=off: upstream wifi port skipped (no behavior change)"; exit 0 ;;
  scan-rssi|scan-rssi+ra) ;;
  *) fail "unknown WIFI_PORT='$WIFI_PORT' (expected off/scan-rssi/scan-rssi+ra)" ;;
esac

DST="$WRT/target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtl_ax_ap"
[ -d "$DST" ] || fail "找不到驱动目录 $DST（overlay 未执行？）"

# ---------- 硬护栏：单 PE1 参考基线 ----------
[ ! -e "$DST/pe-core.c" ] || fail "禁止引入双 PE：检测到 pe-core.c"
! grep -q 'pe-core\.o' "$DST/Makefile" || fail "禁止引入双 PE：Makefile 引用 pe-core.o"
[ "$(md5sum "$DST/pe-tx-code.h" | cut -d' ' -f1)" = 7eb49893f43b897bf03fa82ae2323984 ] \
  || fail "pe-tx-code.h md5 不符（单 PE1 微码被改）"
[ "$(grep -c '0x' "$DST/pe-tx-code.h")" = 4076 ] || fail "pe-tx-code.h 指令数 != 4076"
! grep -q 'RTL_AX_TX_WD_PER_RING' "$DST/rx-geometry.h" || fail "带入 0.8.3 WD 保留改动"

echo "=== upstream single-PE WiFi port: $WIFI_PORT ==="
echo "guard: PE1/4076words/md5=7eb49893 OK, no pe-core.c, no WD-retain"

python3 - "$DST" "$WIFI_PORT" <<'PY'
import pathlib, sys
DST = pathlib.Path(sys.argv[1]); PORT = sys.argv[2]
# C0 skeleton: PE baseline guards enforced by shell section above.
# B1/B2 porting lands in C1/C2; refuse to silently no-op if enabled early.
if PORT != 'off':
    raise SystemExit('ERROR: wifi_port=%s requested but porting code lands in C1/C2' % PORT)
print('UPSTREAM_WIFI_PORT_SKELETON_OK (port=off, baseline guards passed)')
PY

echo "UPSTREAM_WIFI_PORT_SCRIPT_OK=True (port=$WIFI_PORT, skeleton)"
