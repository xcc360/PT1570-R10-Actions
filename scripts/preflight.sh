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
# CI 只读 .github/workflows/ 下的权威文件；根目录同名副本只是本地备份，
# 仓库里可以不存在（2026-11-10 run #5 因脚本强依赖该副本而 exit 2）。
for f in \
  .github/workflows/build-pt1570-fit.yml \
  Config-PT1570-FIT.txt Config-EXTRA.txt customize.sh \
  files/etc/uci-defaults/99-pt1570-fit \
  board/devices/pt1570-r10.mk.inc board/devices/pt1570-h10.mk.inc \
  board/dts/rtl9617c-pt1570-r10.dts board/dts/rtl9617c-pt1570-h10.dts \
  scripts/apply-board.sh scripts/preflight.sh scripts/patch-upstream.sh \
  migration/device-preflight.sh migration/MIGRATION-CHECKLIST.md ; do
  need "$f"
done

echo "=== 2. workflow 副本一致性（根目录副本可选） ==="
if [ ! -f build-pt1570-fit.yml ]; then
  ok "仅 CI 权威文件（仓库无根目录副本）"
elif cmp -s build-pt1570-fit.yml .github/workflows/build-pt1570-fit.yml; then
  ok "COPIES_IDENTICAL"
else
  bad "两份 workflow 不一致（改动后要同步）"
fi

echo "=== 3. YAML 严格解析 ==="
if python3 -c 'import yaml' 2>/dev/null; then
  if python3 - <<'PY'
import yaml, pathlib, sys
p = pathlib.Path('.github/workflows/build-pt1570-fit.yml')
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
         scripts/apply-board.sh scripts/preflight.sh scripts/patch-upstream.sh \
         migration/device-preflight.sh; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done
# sh 脚本也用 sh -n 过一遍
for f in files/etc/uci-defaults/99-pt1570-fit migration/device-preflight.sh; do
  if sh -n "$f" 2>/dev/null; then ok "sh -n $f"; else bad "sh -n $f"; fi
done

echo "=== 4b. R10 网口接线兜底（2026-11-13 真机实证 lan0/lan2/lan3/lan4，无 lan1） ==="
U99=files/etc/uci-defaults/99-pt1570-fit
grep -q "for p in lan0 lan2 lan3 lan4" "$U99" \
  && ok "99-pt1570-fit 含 br-lan ports 兜底 lan0/lan2/lan3/lan4" \
  || bad "99-pt1570-fit 缺 br-lan ports 兜底（lan0 会游离，口不通灯不亮）"
grep -q "LED_EPHY0" "$U99" && grep -q "dev='lan0'" "$U99" \
  && ok "99-pt1570-fit 含 LED_EPHY0 改绑 lan0" \
  || bad "99-pt1570-fit 缺 LED_EPHY0 改绑（面板灯恒灭）"

echo "=== 4c. sysupgrade 机型校验（2026-11-14 真机实证：pt1500-fip.sh 覆盖修复） ==="
AB=scripts/apply-board.sh
grep -q "removed upstream pt1500-fip.sh" "$AB" \
  && ok "apply-board.sh 编译期移除 pt1500-fip.sh" \
  || bad "apply-board.sh 未移除 pt1500-fip.sh（会报 'this image is for youhua,pt1500-h10' 且写错 fip 卷）"
grep -q "CI_KERNPART=fit" "$AB" \
  && ok "apply-board.sh 校验升级目标卷 = fit" \
  || bad "apply-board.sh 缺 fit 卷升级断言"
grep -q "this image is for youhua,pt1500-h10" .github/workflows/build-pt1570-fit.yml \
  && ok "workflow 镜像侧断言无 PT1500-H10 机型检查残留" \
  || bad "workflow 缺 sysupgrade 机型校验断言（产物会悄悄带回坏脚本）"

echo "=== 5. R10 机型隔离与 UBI 命名 ==="
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
WF=.github/workflows/build-pt1570-fit.yml
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

echo "=== 9. 软件包基线（tailscale 三件套，vlmcsd 已移除） ==="
EXTRA=Config-EXTRA.txt
for p in tailscale luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn; do
  grep -q "^CONFIG_PACKAGE_${p}=y$" "$EXTRA" && ok "基线含 $p" || bad "基线缺 $p"
done
grep -q '^CONFIG_PACKAGE_kmod-tun=y$' "$EXTRA" && ok "tailscale 依赖 kmod-tun 已启用" || bad "缺 kmod-tun"
! grep -q 'CONFIG_PACKAGE_vlmcsd' "$EXTRA" && ok "基线已移除 vlmcsd" || bad "基线仍含 vlmcsd"
! grep -q 'immortalwrt/packages.git' "$WF" && ok "workflow 无 vlmcsd 包注入" || bad "workflow 仍含 vlmcsd 注入"
! grep -q 'iw-luci' "$WF" && ok "workflow 无 luci-app-vlmcsd 注入" || bad "workflow 仍含 luci 注入"
grep -q 'user-requested packages (tailscale baseline)' "$WF" && ok "Configure 有 3 包硬断言" || bad "Configure 缺 3 包硬断言"
grep -q 'Config-EXTRA.txt' customize.sh && ok "customize.sh 会追加基线" || bad "customize.sh 未追加基线"

echo "=== 10. 失败可诊断性（Compile + feeds） ==="
grep -q 'build.log' "$WF" && ok "编译日志落盘" || bad "编译日志未落盘"
grep -q 'step-feeds.log' "$WF" && ok "feeds 步骤日志落盘" || bad "feeds 步骤日志未落盘"
grep -q '失败前最后进度' "$WF" && ok "feeds 失败点进度上报" || bad "缺 feeds 失败点进度上报"
grep -q 'STEP: feeds install -a' "$WF" && ok "feeds 子步骤有进度标记" || bad "缺 feeds 子步骤进度标记"
[ "$(grep -c '::error::' "$WF")" -ge 4 ] && ok "失败错误写成 annotation" || bad "失败错误未写 annotation"
grep -q 'Upload build log (always)' "$WF" && ok "失败也上传日志" || bad "缺 always 日志上传"
grep -q 'if: \${{ always() }}' "$WF" && ok "test_only 失败也上传日志" || bad "test_only 失败时日志不会上传"

echo "=== 11. PE 固件前置构建（rtl_ax_ap 驱动硬依赖） ==="
# run #7 教训：pe-tx-code.h 被上游 .gitignore 排除，OpenWrt 不会自动生成；
# 缺少它会在 target/linux/compile 阶段直接失败，且耗时 40 分钟后才暴露。
for t in 'clang-18' 'lld-18' 'llvm-18'; do
  grep -q "$t" "$WF" && ok "依赖清单含 $t" || bad "依赖清单缺 $t"
done
grep -q 'name: Build PE firmware (pe-tx-code.h)' "$WF" \
  && ok "有 PE 构建步骤" || bad "缺 PE 构建步骤"
grep -q 'make -C target/linux/rtl9617c/pe' "$WF" \
  && ok "会调用上游 pe/Makefile" || bad "未调用 pe/Makefile"
grep -q 'pe-tx-code.h 未生成或为空' "$WF" \
  && ok "头文件存在性硬断言" || bad "缺头文件硬断言"
grep -q 'pe_tx_program' "$WF" \
  && ok "头文件内容硬断言" || bad "缺头文件内容硬断言"
CLONE_LINE=$(grep -n 'name: Clone rtl9617c-openwrt source' "$WF" | head -1 | cut -d: -f1)
PE_LINE=$(grep -n 'name: Build PE firmware (pe-tx-code.h)' "$WF" | head -1 | cut -d: -f1)
CFG_LINE=$(grep -n 'name: Configure$' "$WF" | head -1 | cut -d: -f1)
if [ -n "${CLONE_LINE:-}" ] && [ -n "${PE_LINE:-}" ] && [ -n "${CFG_LINE:-}" ] \
   && [ "$CLONE_LINE" -lt "$PE_LINE" ] && [ "$PE_LINE" -lt "$CFG_LINE" ]; then
  ok "步骤顺序 Clone($CLONE_LINE) < PE($PE_LINE) < Configure($CFG_LINE)"
else
  bad "PE 步骤顺序错误（必须在 Clone 之后、Configure 之前）"
fi
grep -q "default: '20b4cf4490ca55cc406d07e391691efa8cd8a087'" "$WF" \
  && ok "源码 ref 用完整 SHA（避免短 SHA fetch 失败后回退分支）" \
  || bad "源码 ref 仍是短 SHA"

echo "=== 12. Rust 交叉编译 std（tyfza1-pon-control 硬依赖） ==="
# run #9 教训：Rust 包用 host cargo 交叉编译 --target aarch64-unknown-linux-musl，
# host rustup 必须预装该目标 std，否则 1 小时后才在 cargo 阶段报 E0463。
grep -q 'rustup target add aarch64-unknown-linux-musl' "$WF" \
  && ok "会补 aarch64 musl Rust std" || bad "缺 rustup target add"
grep -q 'command -v rustup' "$WF" \
  && ok "rustup 存在性检查" || bad "缺 rustup 存在性检查"
grep -q 'runner 缺 rustup' "$WF" \
  && ok "rustup 缺失时有明确报错" || bad "rustup 缺失报错不明"

echo "=== 13. Configure 顺序（run #10 根因：空 config defconfig 会污染 .config） ==="
# 上游 target-metadata.pl 硬编码 default TARGET_mediatek：空 .config 上的
# make defconfig 会先选中 mediatek/filogic/openwrt_one，把它的包集（含官方
# kmod-mac80211/kmod-cfg80211，与 kmod-rtl-ax-ap 自带 .ko 冲突）写成显式值，
# 并把设备包写成显式 n。必须先写配置再 defconfig。
FIST_DEFCONFIG=$(grep -n 'rm -f .config' "$WF" | head -1 | cut -d: -f1)
CFGLINE=$(grep -n 'name: Configure$' "$WF" | head -1 | cut -d: -f1)
if [ -n "${FIST_DEFCONFIG:-}" ] && [ -n "${CFGLINE:-}" ] \
   && [ "$FIST_DEFCONFIG" -gt "$CFGLINE" ]; then
  ok "Configure 先初始化 .config（rm -f .config 在第 $FIST_DEFCONFIG 行）"
else
  bad "Configure 步骤缺少 rm -f .config 初始化（会在空配置上跑 defconfig）"
fi
# make defconfig 的第一次出现必须晚于 cat Config-PT1570-FIT.txt
FIRST_DEF=$(grep -nE '^[[:space:]]*make defconfig[[:space:]]*$' "$WF" | head -1 | cut -d: -f1)
FIRST_CAT=$(grep -n 'cat "$GITHUB_WORKSPACE/Config-PT1570-FIT.txt" >> .config' "$WF" | head -1 | cut -d: -f1)
if [ -n "${FIRST_DEF:-}" ] && [ -n "${FIRST_CAT:-}" ] && [ "$FIRST_CAT" -lt "$FIRST_DEF" ]; then
  ok "首次 make defconfig（行 $FIRST_DEF）晚于写入基础配置（行 $FIRST_CAT）"
else
  bad "首次 make defconfig 跑在基础配置写入之前（run #10 污染根因）"
fi
grep -q '检测到污染包' "$WF" \
  && ok "Configure 有污染包反向断言" || bad "缺污染包反向断言"
grep -q '被显式 n 压住' "$WF" \
  && ok "Configure 有设备包正向断言" || bad "缺设备包正向断言"

echo "=== 14. WiFi 固件随镜像打包 + factory 提取修补（真机验证结论） ==="
# 真机 initramfs 验证：上游没有任何包安装 rtl8852c/rtl8192xb 的 AP 固件，
# 驱动 request_firmware 直接 -2，WiFi 完全起不来。只能靠 files/ overlay 打包。
FW="$ASSETS/files/lib/firmware/realtek/tyfza1"
if [ -d "$FW" ]; then
  ok "存在 $FW"
else
  bad "缺少 WiFi 固件目录 files/lib/firmware/realtek/tyfza1"
fi
for spec in \
  rtl8852c-u1-ap.bin:406448 rtl8852c-u2-ap.bin:369160 \
  rtl8192xb-u1-ap.bin:387680 rtl8192xb-u2-ap.bin:387752 \
  array_mp_8852c_nctl_reg.bin:14256 array_mp_8852c_nctl_reg_a.bin:14152 \
  array_mp_8192xb_nctl_reg.bin:11368 ; do
  name=${spec%%:*}; size=${spec##*:}
  if [ -f "$FW/$name" ]; then
    actual=$(stat -c %s "$FW/$name")
    [ "$actual" = "$size" ] && ok "$name ($size B)" || bad "$name 大小 $actual != $size"
  else
    bad "缺少 WiFi 固件 $name"
  fi
done
n=$(find "$FW" -maxdepth 1 -type f -name '*.bin' 2>/dev/null | wc -l)
[ "$n" = 7 ] && ok "WiFi 固件 7/7" || bad "WiFi 固件数量 $n != 7"

# RFE54 射频参数表 + TSSI 热补偿曲线（2026-11-13 真机定位的第二个断点）
# 驱动按 realtek/tyfza1/<chip>/RFE54/ 与 <chip>/tssi-thermal-*.bin 请求，
# 缺一个就在 phy/fem 阶段失败，probe -EINVAL，phy0/phy1 都不出现。
rfe=$(find "$FW" -path '*RFE54*' -name '*.txt' | wc -l)
[ "$rfe" -ge 40 ] && ok "RFE54 参数表 $rfe 个" || bad "RFE54 参数表只有 $rfe 个（期望 ≥40）"
for spec in rtl8852ce/tssi-thermal-5g.bin:360 rtl8192xbe/tssi-thermal-2g.bin:120 \
            rtl8852ce/RFE54/PHY_REG.txt:27429 \
            rtl8852ce/RFE54/RTK66587_BPF/PHY_REG.txt:2351 \
            rtl8192xbe/RFE54/RTK66287/PHY_REG.txt:1856 ; do
  rel=${spec%:*}; size=${spec##*:}
  if [ -f "$FW/$rel" ]; then
    actual=$(stat -c %s "$FW/$rel")
    [ "$actual" = "$size" ] && ok "$rel ($size B)" || bad "$rel 大小 $actual != $size"
  else
    bad "缺少参数文件 $rel"
  fi
done
# 厂商原表 RU106/2T 6GHz 的两处 PShape 行缺列（一个 8 列只给 7 个 0，
# 另一个 1 列完全为空），驱动按列数逐个 fscanf 会 -EINVAL，必须补零。
if awk -F'\t' '$1=="PShape"{c=0; for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) c++; if(c!=8) exit 1}' \
     "$FW/rtl8852ce/RFE54/TXPWR_LMT_RU_6G_LPI.txt"; then
  ok "RU_6G_LPI 各 PShape 行均为 8 列"
else
  bad "RU_6G_LPI 仍有 PShape 行不是 8 列（驱动会 -EINVAL）"
fi
if awk -F'\t' '$1=="PShape"{c=0; for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) c++; if(c!=1) exit 1}' \
     "$FW/rtl8852ce/RFE54/TXPWR_LMT_RU_6G_VLP.txt"; then
  ok "RU_6G_VLP 各 PShape 行均为 1 列"
else
  bad "RU_6G_VLP 仍有 PShape 行为空（驱动会 -EINVAL）"
fi

# 默认无线配置：刷完就要能看到 WiFi（两颗射频都 enabled）
if [ -f "$ASSETS/files/etc/config/wireless" ]; then
  dis=$(grep -c "option disabled '0'" "$ASSETS/files/etc/config/wireless")
  [ "$dis" = 2 ] && ok "默认 wireless 配置启用 2 个 radio" \
                 || bad "默认 wireless 配置启用 radio 数 $dis != 2"
else
  bad "缺少默认无线配置 files/etc/config/wireless"
fi

# tyfza1-factory 的 factory_blob 把临时文件 mv 到 "$2"（长度）而不是 "$3"（目标路径），
# 导致 /lib/firmware 下校准文件全是悬空链接。修补必须落在镜像里的脚本上。
grep -q 'mv "\$tmp" "\$3"' scripts/patch-upstream.sh \
  && ok "patch-upstream.sh 修 factory_blob 目标参数" \
  || bad "patch-upstream.sh 未修 factory_blob"
grep -q 'files/lib/firmware/realtek/tyfza1' scripts/patch-upstream.sh \
  && ok "patch-upstream.sh 校验 WiFi 固件" || bad "patch-upstream.sh 不校验固件"

PATCH_LINE=$(grep -n 'name: Patch upstream packages (factory extraction)' "$WF" | head -1 | cut -d: -f1)
FILES_LINE=$(grep -n 'name: Apply custom rootfs files' "$WF" | head -1 | cut -d: -f1)
VERIFY_LINE=$(grep -n 'name: Verify image payload' "$WF" | head -1 | cut -d: -f1)
COMPILE_LINE=$(grep -n 'name: Compile$' "$WF" | head -1 | cut -d: -f1)
if [ -n "${PATCH_LINE:-}" ] && [ -n "${FILES_LINE:-}" ] \
   && [ "$FILES_LINE" -lt "$PATCH_LINE" ]; then
  ok "步骤顺序 注入 files($FILES_LINE) < 打补丁($PATCH_LINE)"
else
  bad "缺 Patch upstream packages 步骤，或顺序不在 files 注入之后"
fi
if [ -n "${VERIFY_LINE:-}" ] && [ -n "${COMPILE_LINE:-}" ] \
   && [ "$COMPILE_LINE" -lt "$VERIFY_LINE" ]; then
  ok "编译后校验镜像内容（行 $VERIFY_LINE）"
else
  bad "缺 Verify image payload 步骤，或不在 Compile 之后"
fi
grep -q 'WIFI_FIRMWARE_OK=True' "$WF" \
  && ok "镜像固件校验有正向标记" || bad "缺 WIFI_FIRMWARE_OK 断言"
grep -q 'FACTORY_PATCH_OK=True' "$WF" \
  && ok "镜像补丁校验有正向标记" || bad "缺 FACTORY_PATCH_OK 断言"

echo "=== 15. 默认 WAN=pon0.1101 + PPPoE + PON FE（2026-11-11 真机实证） ==="
# Run14 刷入能启动但 IPv4 完全失效、IPv6 可访问，根因是上游 90-tyfza1-pon-wan
# 照抄原厂 PT1500 布局：untagged pon0 收不到 PADO，且 pon.pon.offload=0（FE 关）
# 时单播上行帧被静默丢弃，PADS 之后 LCP ConfReq 无回应 → Modem hangup。
# 修法（95-pt1570-wan-default）：wan.device=pon0.1101（8021q）+ proto=pppoe
# + pon.pon.offload=1 + firewall flow_offloading(_hw)=1。真机打开 FE 后
# 立刻 PAP 通过、IPCP 拿到 100.125.x.x。脚本必须保留"只改默认值"的边界。
WAN_UC=files/etc/uci-defaults/95-pt1570-wan-default
if [ -f "$WAN_UC" ]; then
  ok "存在 $WAN_UC"
  grep -q 'network.wan.device="\$vlan_dev"' "$WAN_UC" \
    && ok "脚本把 wan.device 设为 pon0.<wan_vlan>" || bad "脚本没设置 wan.device=pon0.\$vlan_dev"
  grep -q "wan_vlan=1101" "$WAN_UC" \
    && ok "R10 实测 VLAN 1101（非上游 EPON 默认 3961）" || bad "缺 wan_vlan=1101"
  grep -q 'network.wan.proto=.pppoe.' "$WAN_UC" \
    && ok "WAN 协议 PPPoE" || bad "WAN 不是 PPPoE"
  grep -q 'pon.pon.offload=.1.' "$WAN_UC" \
    && ok "打开 PON 转发引擎（单播上行必需）" || bad "没打开 pon.pon.offload=1"
  grep -q 'case "\$wan_dev" in' "$WAN_UC" \
    && ok "先判 wan.device 再动手" || bad "缺少 wan.device 判定"
  grep -q 'type=8021q' "$WAN_UC" \
    && ok "建 8021q VLAN 设备" || bad "缺少 8021q 设备判定"
  grep -q 'board_name' "$WAN_UC" \
    && ok "按 board_name 限定 R10" || bad "缺少 board_name 限定"
  # 命名必须在 90-tyfza1-pon-wan 之后，保证看到上游默认值
  case "$(basename "$WAN_UC")" in
    9[5-9]-*) ok "uci-defaults 排序在 90 之后" ;;
    *) bad "脚本名不在 95..99，无法保证在 90-tyfza1-pon-wan 之后执行" ;;
  esac
else
  bad "缺少 $WAN_UC（默认 WAN 会退回 pon0.3961 + FE off，IPv4 拨不上）"
fi

# WiFi 诊断：开关式资产，默认开着出调试镜像；关掉时不得残留 DEVMEM
if [ -f scripts/patch-wifi-diag.sh ]; then
  ok "存在 scripts/patch-wifi-diag.sh"
  grep -q 'rtl_ax_diag_dump' scripts/patch-wifi-diag.sh \
    && ok "诊断脚本注入 rtl_ax_diag_dump" || bad "诊断脚本没有打点函数"
  [ "$(grep -c 'rtl_ax_diag_dump(radio' scripts/patch-wifi-diag.sh)" -ge 4 ] \
    && ok "打点覆盖 enter/ring/wcpu/download 四段" || bad "打点数不足，定位不到 ring_prepare 之外的卡点"
  # 幂等：已打点时直接跳过
  grep -q 'WIFI_DIAG_SKIP=True' scripts/patch-wifi-diag.sh \
    && ok "诊断脚本幂等" || bad "诊断脚本缺少幂等保护"
else
  bad "缺少 scripts/patch-wifi-diag.sh"
fi
if [ -f Config-DIAG.txt ]; then
  # CONFIG_DEVMEM 属内核符号，必须由 patch-wifi-diag.sh 写进 target 的 config-6.18；
  # 写顶层 .config 会被 make defconfig 丢掉（run #13 已踩过）。
  ! grep -q '^CONFIG_DEVMEM=y$' Config-DIAG.txt \
    && ok "Config-DIAG 不再放内核符号（会 defconfig 丢弃）" \
    || bad "Config-DIAG 又写回 CONFIG_DEVMEM 了，它会被 defconfig 丢掉"
  grep -q 'target/linux/rtl9617c/config-6.18' scripts/patch-wifi-diag.sh \
    && ok "诊断脚本把 DEVMEM 写进内核 config-6.18" \
    || bad "诊断脚本没有写内核 config-6.18（/dev/mem 不会生效）"
  grep -q '^CONFIG_BUSYBOX_CONFIG_DEVMEM=y$' Config-DIAG.txt \
    && ok "Config-DIAG 打开 busybox devmem" || bad "Config-DIAG 缺 busybox devmem"
else
  bad "缺少 Config-DIAG.txt"
fi
grep -q 'name: Patch WiFi driver diagnostics' "$WF" \
  && ok "workflow 有 WiFi 诊断步骤" || bad "workflow 缺少 Patch WiFi driver diagnostics"
grep -q 'if: \${{ inputs.wifi_diag }}' "$WF" \
  && ok "诊断步骤受 wifi_diag 开关控制" || bad "诊断步骤没有 wifi_diag 开关"
grep -q 'WIFI_DIAG: \${{ inputs.wifi_diag }}' "$WF" \
  && ok "Configure 收到 WIFI_DIAG" || bad "Configure 没有 WIFI_DIAG env"
grep -q '正式产物不允许 CONFIG_DEVMEM' "$WF" \
  && ok "关掉开关时断言不得带 DEVMEM" || bad "缺少 DEVMEM 的反向断言"
grep -q 'WAN_DEFAULT_OK=True' "$WF" \
  && ok "镜像校验断言默认 WAN=pon0" || bad "镜像校验缺 WAN_DEFAULT_OK"

echo "=== 16. 统一 UBI 方案自洽启动（run15 回归，2026-11-13 二次修订） ==="
# 差分实证（逐个解包 fw12~fw22 内嵌 DTB）：
#   * 用户确认 U-Boot env 已清空恢复默认（pt1570.env 无 bootargs），
#     fdt_chosen() 里 board_fdt_chosen_bootargs() 返回 NULL，`if (str)` 不成立，
#     DTB 的 bootargs 不会被覆盖 —— "NAND env 残留污染"不是根因；
#   * 用户确认 Run14 刷机验证能启动（当时仅 IPv4 不通、IPv6 可访问，
#     已由 95-pt1570-wan-default 单独修复），说明刷入态启动本来是通的；
#   * fw12/fw14（能启动）  : bootargs 无 root= / 无 u-boot,version
#     fw15..fw22（起不来）: 多了 root=/dev/fitblk0 rootwait rootfstype=squashfs
#                            和 u-boot,version="2025.01"
#     FIT 结构 / rootdisk phandle / 内核配置两边完全一致；
#   * 挂根由内核侧完成：CONFIG_MTD_ROOTFS_ROOT_DEV 为 chosen.rootdisk 建
#     ubiblock，510-* fitblk 驱动 `if (!ROOT_DEV) ROOT_DEV = bd_dev;` 自设根
#     设备（/dev/fit0）；fdt_chosen() 无条件写 u-boot,version 满足门闩。
#     所以 DTS 不该覆盖 /chosen，尤其不能写 root= / ubi.mtd / ubi.block。
R10_DTS=board/dts/rtl9617c-pt1570-r10.dts
if [ -f "$R10_DTS" ]; then
  # 只检查 DTS 正文里真正生效的 bootargs 赋值行（注释里出现不算）
  DTS_BA=$(grep -E '^\s*bootargs\s*=' "$R10_DTS" || true)
  if [ -n "$DTS_BA" ]; then
    for badtok in 'root=' 'rootwait' 'rootfstype=' 'ubi.mtd=' 'ubi.block='; do
      case "$DTS_BA" in
        *"$badtok"*) bad "DTS 的 bootargs 含 $badtok（run15 回归，应交给内核/驱动处理）" ;;
      esac
    done
    ok "DTS 的 bootargs 无 root=/rootwait/ubi.*（如有）"
  else
    ok "DTS 未覆盖 bootargs（沿用上游 dtsi，Run14 已验证形态）"
  fi
  if grep -qE '^\s*u-boot,version\s*=' "$R10_DTS"; then
    bad "DTS 写了 u-boot,version —— U-Boot fdt_chosen() 会无条件写入，多余"
  else
    ok "DTS 未写 u-boot,version（由 U-Boot 注入）"
  fi
  grep -q 'RTL9617C UBI' "$R10_DTS" \
    && ok "model 显示 RTL9617C UBI" || bad "model 不是 RTL9617C UBI（状态页会显示成 ABI）"
  ! grep -q 'FIT ABI' "$R10_DTS" \
    && ok "DTS 已无 FIT ABI 命名" || bad "DTS 仍残留 FIT ABI 命名"
else
  bad "缺少 $R10_DTS"
fi

if [ -f scripts/verify-fit-boot.py ]; then
  ok "存在 scripts/verify-fit-boot.py"
  python -c "compile(open('scripts/verify-fit-boot.py').read(),'verify-fit-boot.py','exec')" 2>/dev/null \
    && ok "校验脚本语法通过" || bad "scripts/verify-fit-boot.py 语法错误"
  grep -q 'FORBIDDEN_BOOTARGS' scripts/verify-fit-boot.py \
    && ok "校验脚本禁止 bootargs 里的 root=/rootwait/ubi.*" || bad "校验脚本没拦 run15 回归"
  grep -q 'linux,ubi' scripts/verify-fit-boot.py \
    && ok "校验脚本检查 linux,ubi 分区" || bad "校验脚本没检查 UBI 自动 attach 前提"
  grep -q 'rootdisk' scripts/verify-fit-boot.py \
    && ok "校验脚本检查 rootdisk -> volname=fit" || bad "校验脚本没检查 rootdisk"
  grep -q '"ABI" in model' scripts/verify-fit-boot.py \
    && ok "校验脚本拒绝 ABI 命名" || bad "校验脚本没检查 model 命名"
else
  bad "缺少 scripts/verify-fit-boot.py（无法在 CI 拦住不可启动的镜像）"
fi

# 配置文件侧的开关：UIMAGE_FIT_BLK 在 target，MTD_ROOTFS_ROOT_DEV 在 generic
grep -q '^CONFIG_UIMAGE_FIT_BLK=y$' Config-PT1570-FIT.txt 2>/dev/null \
  && ok "Config-PT1570-FIT 里也有 UIMAGE_FIT_BLK=y" \
  || echo "  --   UIMAGE_FIT_BLK 由 target/linux/rtl9617c/config-6.18 提供（不写顶层 config 属正常）"
grep -q '^CONFIG_UIMAGE_FIT_BLK=y$' "${WRT:-/nonexistent}/target/linux/rtl9617c/config-6.18" 2>/dev/null \
  && ok "target config-6.18 打开 CONFIG_UIMAGE_FIT_BLK" \
  || echo "  --   源码树未就位，跳过 UIMAGE_FIT_BLK 检查（CI 的 Configure 步骤会断言）"

# workflow 里必须真的调用校验脚本，否则本地脚本形同虚设
grep -q 'verify-fit-boot.py' "$WF" \
  && ok "workflow 调用 verify-fit-boot.py" || bad "workflow 没有调用 verify-fit-boot.py"
grep -q 'KERNEL_FIT_ROOTFS_OK' "$WF" \
  && ok "workflow 断言编译后内核配置" || bad "workflow 没有断言内核 UIMAGE_FIT_BLK"

echo "=== 17. apk 源 = 北大镜像 25.12-SNAPSHOT + 索引公钥（2026-11-13 真机） ==="
# 真机现象：distfeeds 指到北大镜像后 apk update 报
#   WARNING: ... packages/aarch64_cortex-a53/base/packages.adb: UNTRUSTED signature
# 索引被整份丢弃（只剩本机 156 个包）。根因是镜像索引由 immortalwrt 25.12
# 发布密钥签名，而镜像里只有上游 openwrt-snapshots.pem。补上
# immortalwrt-25.12.pem 后 apk update 变 OK: 10435 distinct packages。
PK="$ASSETS/files/etc/apk/keys/immortalwrt-25.12.pem"
if [ -f "$PK" ]; then
  sz=$(stat -c %s "$PK")
  [ "$sz" = "178" ] && ok "apk 索引公钥 immortalwrt-25.12.pem ($sz B)" \
                    || bad "公钥大小 $sz != 178（内容被破坏）"
  grep -q -- '-----BEGIN PUBLIC KEY-----' "$PK" \
    && ok "公钥是 PEM 格式" || bad "公钥不是 PEM（apk 会忽略，仍报 UNTRUSTED）"
else
  bad "缺少 files/etc/apk/keys/immortalwrt-25.12.pem（apk 更新会报 UNTRUSTED signature）"
fi
grep -q 'immortalwrt-25.12.pem' customize.sh \
  && ok "customize.sh 注释里点明公钥依赖" || echo "  --   customize.sh 未提及公钥（仅注释，非致命）"

for pat in 'WRT_APK_MIRROR:-https://mirrors.pku.edu.cn/immortalwrt' \
           'WRT_APK_RELEASE:-25.12-SNAPSHOT' \
           'WRT_APK_REPO_ARCH:-aarch64_cortex-a53' ; do
  grep -q -- "$pat" customize.sh && ok "customize.sh 默认值 $pat" || bad "customize.sh 缺 $pat"
done
grep -q 'WRT_APK_MIRROR" = "none"' customize.sh \
  && ok "可用 WRT_APK_MIRROR=none 关闭外部源" || bad "没有关闭外部源的开关"
grep -q 'APK_MIRROR_BASE 显式指定' customize.sh \
  && ok "APK_MIRROR_BASE 仍可覆盖内置镜像" || bad "APK_MIRROR_BASE 覆盖逻辑被破坏"
feeds=$(grep -cE '^WRT_APK_FEEDS=' customize.sh || true)
[ "$feeds" = "1" ] && ok "feed 列表只有一个来源（防重复）" || bad "WRT_APK_FEEDS 定义 $feeds 处"
for f in base luci packages routing telephony; do
  grep -qE "^WRT_APK_FEEDS=.*\b$f\b" customize.sh \
    && ok "默认 feed 含 $f" || bad "默认 feed 缺 $f 目录（镜像上有该 feed）"
done

ARCH_UC=files/etc/uci-defaults/91-pt1570-apk-arch
if [ -f "$ARCH_UC" ]; then
  ok "存在 $ARCH_UC"
  grep -q "aarch64_cortex-a53" "$ARCH_UC" \
    && ok "首启脚本补 aarch64_cortex-a53" || bad "首启脚本没写 a53（镜像包会被拒装）"
  grep -q 'grep -qx' "$ARCH_UC" \
    && ok "首启脚本幂等（已存在就不重复写）" || bad "首启脚本不幂等"
  [ -x "$ARCH_UC" ] && ok "首启脚本可执行" || bad "首启脚本没有可执行位"
else
  bad "缺少 $ARCH_UC（ROM 的 /etc/apk/arch 只有 a55，a53 包装不上）"
fi

grep -q 'APK_SOURCE_OK=True' "$WF" \
  && ok "镜像校验有 APK_SOURCE_OK 标记" || bad "镜像校验缺 APK_SOURCE_OK 断言"
grep -q "UNTRUSTED signature" "$WF" \
  && ok "workflow 记录 UNTRUSTED 排查背景" || echo "  --   workflow 未提及 UNTRUSTED（仅注释，非致命）"

echo "=== 18. rpcd exec 插件 / argon 主题设置（2026-11-14 真机实证） ==="
# LuCI「系统 → 主题设置」报 luci.argon/avail -32000 Object not found：
# /usr/libexec/rpcd/luci.argon* 是 CRLF（#!/bin/sh\r 找不到解释器）且 0644，
# rpcd 的 exec 插件一个都不加载。files/ 注入 LF+0755 覆盖，92-* 首启兜底。
RPCD_SRC=files/usr/libexec/rpcd
n=0
for f in "$RPCD_SRC"/luci.argon*; do
  [ -f "$f" ] || continue
  n=$((n+1))
  base=${f##*/}
  head -n1 "$f" | grep -q '^#!/bin/sh$' \
    && ok "$base shebang 是干净的 #!/bin/sh" \
    || bad "$base shebang 异常（CRLF 会让内核找不到 /bin/sh）"
  if grep -q "$(printf '\r')" "$f"; then
    bad "$base 仍含 CR"
  else
    ok "$base 已是 LF"
  fi
  [ -x "$f" ] && ok "$base 可执行（0755）" || bad "$base 没有可执行位（rpcd 不加载）"
done
[ "$n" = 5 ] && ok "argon rpcd 插件 5 个齐全" || bad "argon rpcd 插件数量 $n != 5"

UC=files/etc/uci-defaults/92-pt1570-rpcd-eol
if [ -f "$UC" ]; then
  ok "存在 $UC 兜底脚本"
  [ -x "$UC" ] && ok "兜底脚本可执行" || bad "兜底脚本没有可执行位"
  grep -q 'tr -d' "$UC" && ok "兜底脚本会去除 CR" || bad "兜底脚本没有去 CR"
  grep -q '/etc/init.d/rpcd restart' "$UC" \
    && ok "兜底脚本改完后重启 rpcd" || bad "兜底脚本没重启 rpcd"
else
  bad "缺少 $UC（feed 升级带回 CRLF 时无法自愈）"
fi
grep -q 'RPCD_ARGON_OK=True' "$WF" \
  && ok "镜像校验有 RPCD_ARGON_OK 断言" || bad "镜像校验缺 rpcd/argon 断言"
grep -q 'wrt/files/usr/libexec/rpcd/' "$WF" \
  && ok "workflow 给 rpcd 插件补可执行位" || bad "workflow 没给 rpcd 插件补可执行位"

echo "=== 19. sysupgrade 不保留配置 + br-lan MAC 固定（2026-11-14 真机） ==="
# 现象：系统内更新勾不勾「保留配置」配置都在，只有 U-Boot 刷入才清空。
# A. zz-pt1570-sysupgrade.sh 覆盖 nand_do_restore_config（按 UPGRADE_BACKUP
#    限制恢复）+ platform_do_upgrade（先卸载 /overlay，让 ubirmvol 成功）。
# B. 02_network 只写 network.lan.macaddr，bridge 不应用；br-lan 从 lan0
#    继承随机 MAC，Windows 按网关 MAC 认网络 → 每次重启都是新网络。
ZZ=files/lib/upgrade/zz-pt1570-sysupgrade.sh
if [ -f "$ZZ" ]; then
  ok "存在 $ZZ"
  case "$ZZ" in */zz-*) ok "zz- 前缀保证 include /lib/upgrade 最后 source" ;; *) bad "文件名不是 zz- 前缀（会被 tar.sh 等覆盖）" ;; esac
  grep -q 'UPGRADE_BACKUP' "$ZZ" \
    && ok "配置恢复受 UPGRADE_BACKUP 限制" || bad "未按 UPGRADE_BACKUP 限制配置恢复"
  grep -q 'umount -l /overlay' "$ZZ" \
    && ok "升级前卸载 overlay（ubirmvol 才能成功）" || bad "未卸载 overlay"
  grep -q 'CI_KERNPART=fit' "$ZZ" \
    && ok "升级目标卷 = fit（统一 UBI）" || bad "升级目标卷不是 fit"
else
  bad "缺少 $ZZ（sysupgrade -n 无法清空配置）"
fi
U99=files/etc/uci-defaults/99-pt1570-fit
grep -q 'network.@device\[0\].macaddr' "$U99" \
  && ok "99-pt1570-fit 给 br-lan 显式写 macaddr" || bad "未固定 br-lan MAC"
grep -q '/tmp/tyfza1-factory/lan_mac' "$U99" \
  && ok "MAC 取自 factory lan_mac" || bad "MAC 未取自 factory"
grep -q '已有自定义值则不覆盖' "$U99" \
  && ok "不覆盖用户自定义 MAC" || bad "会覆盖用户自定义 MAC（仅注释检查）"
grep -q 'SYSUPGRADE_KEEP_OK=True' "$WF" \
  && ok "镜像校验有 SYSUPGRADE_KEEP_OK 断言" || bad "缺 SYSUPGRADE_KEEP_OK 断言"
grep -q 'LAN_MAC_OK=True' "$WF" \
  && ok "镜像校验有 LAN_MAC_OK 断言" || bad "缺 LAN_MAC_OK 断言"

echo "=== RESULT ==="
if [ "$FAIL" = "0" ]; then
  echo "PREFLIGHT_OK=True"
else
  echo "PREFLIGHT_OK=False" >&2
  exit 1
fi
