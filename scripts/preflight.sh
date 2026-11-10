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

echo "=== 15. 默认 WAN=pon0 与 WiFi 诊断开关（2026-11-10 真机反馈） ==="
# 上游 90-tyfza1-pon-wan 照抄原厂 PT1500 布局，把 wan.device 绑到
# pon0.<pon.wan_vlan>（默认 3961）。R10 默认要求 WAN=pon0，用 uci-defaults
# 在 90 之后回退；脚本必须保留"只改默认值"的边界，否则会覆盖用户配置。
WAN_UC=files/etc/uci-defaults/95-pt1570-wan-default
if [ -f "$WAN_UC" ]; then
  ok "存在 $WAN_UC"
  grep -q "network.wan.device='pon0'" "$WAN_UC" \
    && ok "脚本把 wan.device 写回 pon0" || bad "脚本没有写 network.wan.device='pon0'"
  grep -q 'pon0\.\$wan_vlan' "$WAN_UC" \
    && ok "脚本识别上游默认 pon0.<wan_vlan>" || bad "脚本没有匹配上游默认设备的 case 分支"
  grep -q 'case "\$wan_dev" in' "$WAN_UC" \
    && ok "先判 wan.device 再动手" || bad "缺少 wan.device 判定"
  grep -q '"8021q"' "$WAN_UC" \
    && ok "只删 8021q 设备" || bad "缺少 8021q 设备判定（可能误删自定义设备）"
  grep -q 'board_name' "$WAN_UC" \
    && ok "按 board_name 限定 R10" || bad "缺少 board_name 限定"
  # 命名必须在 90-tyfza1-pon-wan 之后、99-pt1570-fit 之前/同段，保证看到上游默认值
  case "$(basename "$WAN_UC")" in
    9[5-9]-*) ok "uci-defaults 排序在 90 之后" ;;
    *) bad "脚本名不在 95..99，无法保证在 90-tyfza1-pon-wan 之后执行" ;;
  esac
else
  bad "缺少 $WAN_UC（默认 WAN 会退回 pon0.3961）"
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
  grep -q '^CONFIG_DEVMEM=y$' Config-DIAG.txt \
    && ok "Config-DIAG 打开 CONFIG_DEVMEM" || bad "Config-DIAG 缺 CONFIG_DEVMEM=y"
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

echo "=== RESULT ==="
if [ "$FAIL" = "0" ]; then
  echo "PREFLIGHT_OK=True"
else
  echo "PREFLIGHT_OK=False" >&2
  exit 1
fi
