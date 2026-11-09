#!/bin/bash
# 静态自检：本地和 CI（test_only）都能跑，不联网、不编译、不写源码树。
# 可选 env：ASSETS（资产根）、WRT（源码树；存在时额外校验注入结果）。
#
# 2026-11-09 起范围 R10-only：本脚本会硬断言 workflow / 注入脚本 / DTS
# 均不允许产出 PT1570-H10 固件，并校验 R10 DTS 已按真机 FDT 静态移植。

set -euo pipefail
ASSETS="${ASSETS:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ASSETS"
FAIL=0
ok()   { echo "  OK   $*"; }
bad()  { echo "  FAIL $*" >&2; FAIL=1; }
need() { test -f "$1" && ok "exists ${1#./}" || bad "missing $1"; }

echo "=== 1. 资产齐全（H10 为 DORMANT 留档，不参与构建） ==="
for f in \
  build-pt1570-fit.yml .github/workflows/build-pt1570-fit.yml \
  Config-PT1570-FIT.txt Config-EXTRA.txt customize.sh \
  files/etc/uci-defaults/99-pt1570-fit \
  board/devices/pt1570-r10.mk.inc board/devices/pt1570-h10.mk.inc \
  board/dts/rtl9617c-pt1570-r10.dts board/dts/rtl9617c-pt1570-h10.dts \
  scripts/apply-board.sh scripts/preflight.sh \
  migration/device-preflight.sh migration/MIGRATION-CHECKLIST.md ; do
  need "$f"
done

echo "=== 2. 两份 workflow 一致 ==="
if cmp -s build-pt1570-fit.yml .github/workflows/build-pt1570-fit.yml; then
  ok "COPIES_IDENTICAL"
else
  bad "两份 workflow 不一致（改动后要同步）"
fi

echo "=== 3. YAML 严格解析 ==="
if python3 -c 'import yaml' 2>/dev/null; then
  if python3 - <<'PY'
import yaml, pathlib, sys
p = pathlib.Path('build-pt1570-fit.yml')
d = yaml.safe_load(p.read_text(encoding='utf-8'))
on = d.get(True) or d.get('on')
inputs = on['workflow_dispatch']['inputs']
print('  OK   YAML_PARSE inputs=' + ','.join(sorted(inputs)))
print('  OK   jobs=' + ','.join(sorted(d['jobs'])))
steps = d['jobs']['build']['steps']
print('  OK   STEP_COUNT=' + str(len(steps)))
uses = [s['uses'] for s in steps if 'uses' in s]
for u in uses:
    print('  OK   uses ' + u)
# R10-only 结构断言
assert 'board' not in inputs, 'workflow_dispatch 不应再有 board 选项'
assert sorted(d['jobs']) == ['build'], 'prepare 动态 matrix job 应已删除'
board = d['jobs']['build']['strategy']['matrix']['board']
assert board == ['r10'], 'matrix.board 必须是 [r10]，实为 %r' % board
names = [s.get('name','') for s in steps]
assert 'Guard R10-only' in names, '缺少 R10-only 防呆步骤'
print('  OK   R10_ONLY_STRUCTURE matrix=%r guard=present' % board)
PY
  then
    :
  else
    FAIL=1
  fi
else
  echo "  SKIP PyYAML 不可用（CI 上会执行）"
fi

echo "=== 4. shell 语法 ==="
for f in customize.sh files/etc/uci-defaults/99-pt1570-fit \
         scripts/apply-board.sh scripts/preflight.sh \
         migration/device-preflight.sh; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done
# sh 脚本也用 sh -n 过一遍
for f in files/etc/uci-defaults/99-pt1570-fit migration/device-preflight.sh; do
  if sh -n "$f" 2>/dev/null; then ok "sh -n $f"; else bad "sh -n $f"; fi
done

echo "=== 5. R10 机型隔离与 ABI 关键字 ==="
b=r10
dev="board/devices/pt1570-${b}.mk.inc"
dts="board/dts/rtl9617c-pt1570-${b}.dts"
name="youhua,pt1570-${b}"
grep -q "SUPPORTED_DEVICES += ${name}" "$dev" && ok "$b SUPPORTED_DEVICES" || bad "$b SUPPORTED_DEVICES"
grep -q "DEVICE_DTS := rtl9617c-pt1570-${b}" "$dev" && ok "$b DEVICE_DTS" || bad "$b DEVICE_DTS"
grep -q "IMAGES := sysupgrade.itb" "$dev" && ok "$b FIT output" || bad "$b FIT output"
grep -q "external-static-with-rootfs" "$dev" && ok "$b FIT rootfs" || bad "$b FIT rootfs"
grep -q "UNVERIFIED" "$dts" && ok "$b DTS 仍标 UNVERIFIED（默认禁止刷机）" || echo "  INFO $b DTS 已去除 UNVERIFIED（请用 verified 重编）"
grep -q '#include' "$dts" && ok "$b DTS 复用上游 FIT dtsi" || bad "$b DTS include"
# H10 只做 dormant 留档检查
for f in board/devices/pt1570-h10.mk.inc board/dts/rtl9617c-pt1570-h10.dts; do
  grep -q 'DORMANT' "$f" && ok "H10 资产已标 DORMANT: $f" || bad "H10 资产未标 DORMANT: $f"
done
grep -q "CONFIG_TARGET_ARCH_PACKAGES=\"aarch64_cortex-a55\"" Config-PT1570-FIT.txt \
  && ok "arch=aarch64_cortex-a55" || bad "arch 配置错误"
grep -q 'aarch64_cortex-a55' customize.sh && ok "customize.sh 架构一致" || bad "customize.sh 架构不一致"
grep -q 'CONFIG_PACKAGE_fitblk=y' Config-PT1570-FIT.txt && ok "fitblk 已启用" || bad "fitblk 未启用"

echo "=== 6. 防止误刷 / 防混刷 ==="
WF=build-pt1570-fit.yml
grep -q "DO-NOT-FLASH-EXPERIMENTAL.txt" "$WF" && ok "实验产物带警告文件" || bad "缺实验警告"
grep -q "inputs.dts_status == 'verified'" "$WF" && ok "Release 仅允许 verified" || bad "Release 未限制 dts_status"
grep -q "UNVERIFIED" "$WF" && ok "workflow 会拒绝 verified 但带标记的 DTS" || bad "缺 verified 校验"
grep -q 'pt1570-${{ matrix.board }}-fit-' "$WF" && ok "artifact 名带机型" || bad "artifact 名未隔离机型"
grep -q '\*\${PROFILE}\*' "$WF" && ok "产物按 profile 过滤" || bad "产物未按 profile 过滤"

echo "=== 6b. R10-only 范围硬断言 ==="
MATRIX=$(grep -E '^[[:space:]]*board: \[' "$WF" | tr -d '[:space:]')
[ "$MATRIX" = 'board:[r10]' ] && ok "matrix 仅 r10" || bad "matrix 不是 [r10]：$MATRIX"
! grep -q "options: \[r10, h10, both\]" "$WF" && ok "无双机型 choice 输入" || bad "仍存在双机型 choice 输入"
grep -q 'PT1570_ALLOW_H10' scripts/apply-board.sh && ok "apply-board.sh 默认拒绝 H10" || bad "apply-board.sh 未拒绝 H10"
grep -q 'PT1570_ALLOW_H10' customize.sh && ok "customize.sh 默认拒绝 H10" || bad "customize.sh 未拒绝 H10"
grep -q "R10-only 构建不接受" "$WF" && ok "Resolve 步骤拒绝非 r10" || bad "Resolve 步骤未拒绝非 r10"
grep -q 'Guard R10-only' "$WF" && ok "workflow 含 R10-only 防呆步骤" || bad "缺 R10-only 防呆步骤"

echo "=== 7. 源码树注入结果（可选，仅校验 R10） ==="
if [ -n "${WRT:-}" ] && [ -d "$WRT/target/linux/rtl9617c" ]; then
  test -f "$WRT/target/linux/rtl9617c/dts/rtl9617c-pt1570-r10.dts" \
    && ok "WRT 有 R10 DTS" || bad "WRT 缺 R10 DTS"
  if [ -f "$WRT/target/linux/rtl9617c/dts/rtl9617c-pt1570-h10.dts" ]; then
    bad "WRT 出现 H10 DTS，违反 R10-only 范围"
  else
    ok "WRT 无 H10 DTS（R10-only）"
  fi
  grep -q 'volname = "fit"' "$WRT/target/linux/rtl9617c/dts/rtl9617c-tyfza1.dtsi" \
    && ok "上游 dtsi 含 fit 卷" || bad "上游 dtsi 缺 fit 卷"
  test -f "$WRT/package/utils/fitblk/files/fit.sh" && ok "fitblk 存在" || bad "fitblk 缺失"
else
  echo "  SKIP WRT 未指定（CI 的 Configure 步骤另有硬断言）"
fi

echo "=== 8. R10 DTS 真机 FDT 实证字段 ==="
DTS=board/dts/rtl9617c-pt1570-r10.dts
# 2026-11-09 真机 FDT：realtek,lan-phys = 4 个 phandle（phy0..phy3），4×GE；
# 上游 2p5g.dts 会引入 phy4 HSGMII 与端口 0/1/2/4，与 R10 硬件不符。
grep -q '#include "rtl9617c-tyfza1-4ge.dts"' "$DTS" && ok "include 4GE 板定义" || bad "必须 include rtl9617c-tyfza1-4ge.dts"
! grep -q 'rtl9617c-tyfza1-2p5g.dts' "$DTS" && ok "未误用 2.5G 板定义" || bad "R10 DTS 误 include 2.5G 板定义"
! grep -qE 'phy4|realtek,hsgmii|sgmii' "$DTS" && ok "无外部 2.5G PHY 残留" || bad "DTS 含 2.5G PHY 残留"
grep -q 'tianyi,tyfza1-4ge' "$DTS" && ok "compatible 指向 4ge" || bad "compatible 未指向 4ge"
grep -q 'FDT_VERIFIED' "$DTS" && ok "DTS 记录了真机 FDT 依据" || bad "DTS 缺真机 FDT 依据"
for pin in 'btn-reset' 'btn-wifi' 'lights-toggle'; do
  grep -q "$pin" "$DTS" && ok "按键节点 $pin 已覆盖" || bad "缺按键节点 $pin"
done
for pin in 8 99 103; do
  grep -q "gpio0 $pin GPIO_ACTIVE_LOW" "$DTS" && ok "按键 GPIO$pin 与真机一致" || bad "按键 GPIO$pin 缺失或不符"
done

echo "=== 9. 软件包基线（沿用 HG5585F-CT 6 包） ==="
EXTRA=Config-EXTRA.txt
for p in tailscale luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn \
         vlmcsd luci-app-vlmcsd luci-i18n-vlmcsd-zh-cn; do
  grep -q "^CONFIG_PACKAGE_${p}=y$" "$EXTRA" && ok "基线含 $p" || bad "基线缺 $p"
done
grep -q 'immortalwrt/packages.git' "$WF" && ok "workflow 会补 vlmcsd 包源" || bad "缺 vlmcsd 包注入"
grep -q 'immortalwrt/luci.git' "$WF" && ok "workflow 会补 luci-app-vlmcsd 包源" || bad "缺 luci-app-vlmcsd 包注入"
grep -q 'user-requested packages' "$WF" && ok "Configure 有 6 包硬断言" || bad "Configure 缺 6 包硬断言"
grep -q 'Config-EXTRA.txt' customize.sh && ok "customize.sh 会追加基线" || bad "customize.sh 未追加基线"

echo "=== RESULT ==="
if [ "$FAIL" = "0" ]; then
  echo "PREFLIGHT_OK=True"
else
  echo "PREFLIGHT_OK=False" >&2
  exit 1
fi
