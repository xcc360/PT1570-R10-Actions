#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# PT1570-H10-CU / refactor 基线：回移植 PCIe 主机 + RTL-AX WiFi AP 子系统。
#
# 背景：上游 lyq1996/rtl9617c-openwrt 的 refactor 分支把 rtl9617c target
# 精简成纯 2.5G/PON，删除了整个 PCIe/WiFi 子系统：
#   - target/linux/rtl9617c/files-6.18/drivers/pci/controller/dwc/pcie-rtl9617c.c
#   - target/linux/rtl9617c/files-6.18/drivers/phy/phy-rtl9617c-pcie.c
#   - target/linux/rtl9617c/patches-6.18/200-native-pcie.patch
#   - target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtl_ax_ap/（60 文件）
# 而 PT1570-H10-CU 实机有双 PCIe WiFi6（8852C 10ec:c852 / 8192XB 10ec:0192），
# 必须自包含地补回这套驱动。所有源文件随本资产仓库提供，不依赖 source_ref。
#
# OpenWrt 规范：
#   - 内核驱动放 target/linux/<target>/files-<ver>/drivers/...（原生位置）
#   - 内核补丁放 target/linux/<target>/patches-<ver>/NNN-*.patch
#   - 包名用上游规范 kmod-rtl-ax-ap（不引入 tyfza1 私有前缀）
#   - 幂等：重复执行结果一致；失败即 fail，不留半成品
#
# env: ASSETS=<资产仓库根>  WRT=<源码树>
set -euo pipefail

ASSETS="${ASSETS:-$(cd "$(dirname "$0")/../.." && pwd)}"
WRT="${WRT:-$ASSETS/wrt}"
OVERLAY="$ASSETS/cu-h10/fw/board/pcie"
LEDS_SRC="$ASSETS/cu-h10/fw/board/leds"
WIFI_HDR_SRC="$ASSETS/cu-h10/fw/board/wifi"
WIFI_SRC="$ASSETS/board/wifi/rtl_ax_ap"
WIFI_PATCHES="$ASSETS/refactor/patches"
MODULES_MK="$ASSETS/refactor/modules.mk"
KDIR="$WRT/target/linux/rtl9617c/files-6.18"
PDIR="$WRT/target/linux/rtl9617c/patches-6.18"

fail() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$WRT/target/linux/rtl9617c" ] || fail "找不到源码树 $WRT/target/linux/rtl9617c"
[ -f "$OVERLAY/pcie-rtl9617c.c" ] || fail "PCIe overlay 资产缺失：$OVERLAY"
[ -f "$OVERLAY/phy-rtl9617c-pcie.c" ] || fail "PCIe PHY overlay 资产缺失"
[ -f "$OVERLAY/rtl9617c-sgmii.h" ] || fail "PCIe SGMII 头资产缺失（phy-rtl9617c-pcie.c 依赖 rtl_sgmii_link）"
[ -f "$OVERLAY/200-native-pcie.patch" ] || fail "PCIe patch 资产缺失"
[ -f "$LEDS_SRC/leds-tyfza1.c" ] || fail "LED 控制器源资产缺失：$LEDS_SRC/leds-tyfza1.c"
[ -f "$LEDS_SRC/ledtrig-tyfza1-usb.c" ] || fail "LED USB trigger 源资产缺失"
[ -f "$LEDS_SRC/tyfza1-led.h" ] || fail "LED 公共头资产缺失（linux/tyfza1-led.h）"
[ -f "$WIFI_HDR_SRC/rtl9617c-wifi.h" ] || fail "WiFi 公共头资产缺失（linux/rtl9617c-wifi.h）"
n=$(find "$WIFI_SRC" -maxdepth 1 -type f 2>/dev/null | wc -l)
[ "$n" -ge 60 ] || fail "WiFi 驱动资产 $n 文件 < 60，不完整：$WIFI_SRC"

echo "=== overlay PCIe + WiFi onto refactor ($n wifi files) ==="

# ---- 1. PCIe 主机控制器 + PHY 驱动（refactor 树里目录已删，需重建）----
mkdir -p "$KDIR/drivers/pci/controller/dwc" "$KDIR/drivers/phy"
cp -f "$OVERLAY/pcie-rtl9617c.c"      "$KDIR/drivers/pci/controller/dwc/pcie-rtl9617c.c"
cp -f "$OVERLAY/rtl9617c-pcie-sequence.h" "$KDIR/drivers/pci/controller/dwc/rtl9617c-pcie-sequence.h"
cp -f "$OVERLAY/phy-rtl9617c-pcie.c"  "$KDIR/drivers/phy/phy-rtl9617c-pcie.c"
# phy-rtl9617c-pcie.c 用相对路径 ../net/ethernet/realtek/rtl9617c-sgmii.h 引用
# rtl_sgmii_link()/rtl_sgmii_pcs()。refactor 上游删掉了整个 net/ethernet/realtek
# 子系统，头文件随之消失；RUN#8 首次真正进入 Compile 即死在此头缺失。头文件是
# 自包含的 static inline（只依赖已 include 的 readl/writel/BIT/ARRAY_SIZE），
# 随资产补回原生位置即可，不改驱动源码、不引入 base 的 xram 以太网子系统。
mkdir -p "$KDIR/drivers/net/ethernet/realtek"
cp -f "$OVERLAY/rtl9617c-sgmii.h" "$KDIR/drivers/net/ethernet/realtek/rtl9617c-sgmii.h"
mkdir -p "$PDIR"
cp -f "$OVERLAY/200-native-pcie.patch" "$PDIR/200-native-pcie.patch"
echo "  OK   PCIe host + PHY 驱动 + rtl9617c-sgmii.h + 200-native-pcie.patch"

# ---- 1b. WiFi/mac80211 内核基础设施 patch 集（refactor 上游删了整套 201-214）----
# rtl_ax_ap 驱动直接依赖这些 patch 引入的符号：
#   - 201: Kconfig/Makefile 链（把 rtl_ax_ap 纳入内核构建）
#   - 204: ieee80211_rx_shortcut_{sync,snapshot,account}（驱动 RX 路径调用）
#   - 209: tyfza1_{led_register,unregister}（驱动 LED 调用）+ LEDS_TYFZA1
#   - 803/808/813/814: mac80211 encap/radar/txpower/inline-rx 改造
# 注：base 的 802/805/807/811 已排除（与 refactor 2.5G/flowtable/bridge 重写版
#     冲突且回移植 WiFi 不需要，详见下方说明）。
# 编号用 8xx 避开 refactor 已有的 300/400/650/700-730。
# ---- 1b-2. Taurus 6.18.64 跳过 803 encap-tx-band patch ----
# 803 补丁把 802.3 encap TX 的 band 从 sta 改为 sband；6.18.64 上游已在
# ieee80211_8023_xmit() 用 chanctx_conf->def.chan->band 做了等价修复
# （并带 MLD guard），再套 803 会 Hunk #1 FAILED at tx.c:4650。
# pre-Taurus 基线仍需 803，故按基线条件跳过。
SKIP_803=0
if [ -f "$WRT/target/linux/rtl9617c/dts/rtk-taurus.dtsi" ] \
   || grep -q '^CONFIG_MDIO_REALTEK_TAURUS=y$' \
        "$WRT/target/linux/rtl9617c/config-6.18" 2>/dev/null; then
  SKIP_803=1
fi
np=0
for p in "$WIFI_PATCHES"/*.patch; do
  [ -f "$p" ] || continue
  base=$(basename "$p")
  if [ "$SKIP_803" = 1 ] && [ "$base" = "803-mac80211-encap-tx-band.patch" ]; then
    echo "  OK   skip $base（Taurus 6.18.64 已内置等价 band 修复）"
    continue
  fi
  cp -f "$p" "$PDIR/$base"
  np=$((np+1))
done
# 排除的 base patch（已被 refactor 重写版覆盖或与 2.5G 正解架构冲突）：
#   - 802-native-wifi-ne：base xram eth 的 wifi hook + skb.wifi_miss
#   - 805-flowtable-pppoe-session ↔ refactor 650 flowtable-offload-pppoe
#   - 807-native-bridge-learning ↔ refactor 660/664 bridge-learning/skb-ext
#   - 811-realtek-rtl8221b-private-state：base PHY private probe
# 保留的 7 个全是 refactor 没有对应实现的纯 WiFi/mac80211/leds patch，
# 覆盖驱动实际引用的全部 base patch 符号（804 rx_shortcut_* / 809 tyfza1_led_*）。
MIN_PATCHES=7
if [ "$SKIP_803" = 1 ]; then
  MIN_PATCHES=6
fi
[ "$np" -ge "$MIN_PATCHES" ] || fail "WiFi 基础设施 patch 数 $np < $MIN_PATCHES：$WIFI_PATCHES"
echo "  OK   WiFi/mac80211 基础设施 patch 集（$np 个，8xx 段；Taurus skip_803=$SKIP_803；已排除 802/805/807/811）"

# ---- 1c. TYFZA1 LED 控制器 + USB trigger 源文件（809 patch 引入，refactor 树无）----
# 809-native-leds.patch 只改 drivers/leds/{Kconfig,Makefile}，声明编译
# leds-tyfza1.o 与 ledtrig-tyfza1-usb.o，但两个 .c 源文件在上游 refactor
# 分支不存在（属 files-6.18/drivers/leds/ 原生位置）。缺源文件时内核编译
# 直接失败：RUN#13 `No rule to make target 'drivers/leds/leds-tyfza1.o'`。
# rtl_ax_ap/pci.c 调用 tyfza1_led_register()/tyfza1_led_unregister()，
# 由 leds-tyfza1.c 导出，故必须补回。源文件取自上游 main 分支原实现。
mkdir -p "$KDIR/drivers/leds"
cp -f "$LEDS_SRC/leds-tyfza1.c"     "$KDIR/drivers/leds/leds-tyfza1.c"
cp -f "$LEDS_SRC/ledtrig-tyfza1-usb.c" "$KDIR/drivers/leds/ledtrig-tyfza1-usb.c"
# leds-tyfza1.c 以 <linux/tyfza1-led.h> 引用 struct tyfza1_led 定义与
# tyfza1_led_register/unregister 声明；rtl_ax_ap/pci.c 也用它。
# refactor 树里 files-6.18/include/linux/ 目录存在（soc/realtek/ 等），
# 但该头文件随 LED 子系统一起被删 → RUN#14 fatal error: linux/tyfza1-led.h。
# 按上游 main 的原生位置放回：files-6.18/include/linux/tyfza1-led.h。
mkdir -p "$KDIR/include/linux"
cp -f "$LEDS_SRC/tyfza1-led.h" "$KDIR/include/linux/tyfza1-led.h"
# rtl_ax_ap 的 monitor.h / tx.c 以 <linux/rtl9617c-wifi.h> 引用 RTL9617C WiFi
# 网卡接口声明（rtl_wifi_start/stop、tc_setup、peer_route 等）。该头在上游位于
# files-6.18/include/linux/rtl9617c-wifi.h，refactor 分支同样缺失
# → RUN#15 fatal error: linux/rtl9617c-wifi.h。按上游原生位置放回。
cp -f "$WIFI_HDR_SRC/rtl9617c-wifi.h" "$KDIR/include/linux/rtl9617c-wifi.h"
echo "  OK   TYFZA1 LED 控制器 + USB trigger 源文件 + tyfza1-led.h + rtl9617c-wifi.h"

# ---- 2. rtl_ax_ap WiFi AP 驱动（整目录覆盖，幂等）----
WIFI_DST="$KDIR/drivers/net/wireless/realtek/rtl_ax_ap"
mkdir -p "$WIFI_DST"
cp -a "$WIFI_SRC/." "$WIFI_DST/"
# 上游双 PE 的 pe-core.c 不属于已验证的单 PE1 实现，参考 Makefile 不引用它
rm -f "$WIFI_DST/pe-core.c"
echo "  OK   rtl_ax_ap WiFi 驱动覆盖（$n 文件）"

# ---- 2a. 统一驱动资产 -> refactor 基线适配 ----
# 当前 board/wifi/rtl_ax_ap 是与 R10 base 共用的单一真源，Kconfig 依赖
# RTL9617C_XRAM_ETH、cal 路径用 realtek/tyfza1/…；refactor 基线是 NI 以太网
# + realtek/rtl9617c/… 规范路径，不适配则 CONFIG_RTL_AX_AP 选不上、镜像校验
# 也会因 cal 路径失败。只在编译树副本上改，资产真源保持单一。
python3 - "$WIFI_DST" <<'PY'
import pathlib, sys
d = pathlib.Path(sys.argv[1])
k = d / 'Kconfig'
t = k.read_text(encoding='utf-8')
old = 'depends on PCI && ARCH_RTL9617C && MAC80211 && RTL9617C_XRAM_ETH'
new = 'depends on PCI && ARCH_RTL9617C && MAC80211 && RTL9617C_NI'
if old in t:
    k.write_text(t.replace(old, new, 1), encoding='utf-8')
elif new not in t:
    raise SystemExit('ERROR: Kconfig 既无 XRAM_ETH 也无 NI 依赖，refactor 适配失败')
b = d / 'board-cal.h'
t = b.read_text(encoding='utf-8')
if 'realtek/tyfza1/' in t:
    b.write_text(t.replace('realtek/tyfza1/', 'realtek/rtl9617c/'), encoding='utf-8')
elif 'realtek/rtl9617c/' not in t:
    raise SystemExit('ERROR: board-cal.h cal 路径异常，refactor 适配失败')
print('  OK   refactor 适配：Kconfig->RTL9617C_NI / cal->realtek/rtl9617c')
PY

# ---- 2b. OpenWrt 包定义 modules.mk（refactor 上游删除，kmod-rtl-ax-ap 包必须）----
# 没有它 .config 里就没有 CONFIG_PACKAGE_kmod-rtl-ax-ap，defconfig 会丢弃该包。
# target.mk 会自动 include target/linux/<target>/modules.mk（OpenWrt 标准机制）。
[ -f "$MODULES_MK" ] || fail "缺 modules.mk 资产（kmod 包定义）"
cp -f "$MODULES_MK" "$WRT/target/linux/rtl9617c/modules.mk"
grep -q 'KernelPackage/rtl-ax-ap' "$WRT/target/linux/rtl9617c/modules.mk" \
  || fail "modules.mk 缺 rtl-ax-ap 包定义"
echo "  OK   modules.mk（kmod-rtl-ax-ap 包定义）"

# ---- 3. 内核配置符号：refactor config-6.18 缺 PCIe/WiFi，补进 target config ----
# 这些是 CONFIG_*（内核 .config），不是 OpenWrt 顶层包符号；放进
# target/linux/rtl9617c/config-6.18 由 make defconfig 自动纳入。
TCFG="$WRT/target/linux/rtl9617c/config-6.18"
[ -f "$TCFG" ] || fail "找不到 $TCFG"
python3 - "$TCFG" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
want = [
    'CONFIG_PCI=y',
    'CONFIG_PCI_DOMAINS=y',
    'CONFIG_PCI_DOMAINS_GENERIC=y',
    'CONFIG_PCI_ECAM=y',
    'CONFIG_PCI_HOST_COMMON=y',
    'CONFIG_PCI_MSI=y',
    'CONFIG_PCIEPORTBUS=y',
    'CONFIG_PCIE_DW=y',
    'CONFIG_PCIE_DW_HOST=y',
    'CONFIG_PCIE_RTL9617C=y',
    'CONFIG_PHY_RTL9617C_PCIE=y',
    'CONFIG_CFG80211=m',
    'CONFIG_CFG80211_CRDA_SUPPORT=y',
    'CONFIG_CFG80211_DEFAULT_PS=y',
    'CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y',
    'CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS=y',
    'CONFIG_WLAN=y',
    'CONFIG_WLAN_VENDOR_REALTEK=y',
    'CONFIG_MAC80211=m',
    'CONFIG_MAC80211_HAS_RC=y',
    'CONFIG_MAC80211_LEDS=y',
    'CONFIG_MAC80211_RC_DEFAULT="minstrel_ht"',
    'CONFIG_MAC80211_RC_DEFAULT_MINSTREL=y',
    'CONFIG_MAC80211_RC_MINSTREL=y',
    'CONFIG_RTL_AX_AP=m',
    'CONFIG_LEDS_TYFZA1=y',
    'CONFIG_LEDS_TRIGGER_TYFZA1_USB=m',
]
# 注意：不要加 CONFIG_USB_SUPPORT / USB_NET_DRIVERS / PHY_RTL9617C_USB。
# rtl_ax_ap 是纯 PCIe（depends PCI && RTL9617C_NI，零 USB 依赖），refactor 基线
# 本就无 USB_SUPPORT。run#7 教训：误加 USB_SUPPORT=y 会激活内核 drivers/phy/realtek
# 里上游自带的 PHY_RTK_RTD_USB2PHY/USB3PHY prompt（base/refactor config 均无此符号，
# 无法靠 diff 补齐），syncconfig 逐个冒 NEW。回到 refactor 无 USB 的原生状态即可掐断。
# 显式 is not set：cfg80211/mac80211/pcie 的可选调试项。refactor 原本没有这些符号，
# 启用 cfg80211/pcie 后 syncconfig 会把它们当 (NEW) 弹交互提示，CI 非交互下直接失败
# （run#3 DEVELOPER_WARNINGS / run#4 WEXT / run#5 RTW88 / run#6 VIRT_WIFI / run#7 因误加 USB_SUPPORT 引出 RTD_USB2PHY）。
# 按 base config-6.18 已验证值全量镜像钉死：凡是 base 里写过的 prompt 符号，refactor 侧
# 一律显式给出值，杜绝 syncconfig 再逐轮冒出新的 (NEW)。
unset = [
    'CONFIG_CFG80211_DEBUGFS',
    'CONFIG_CFG80211_DEVELOPER_WARNINGS',
    'CONFIG_CFG80211_CERTIFICATION_ONUS',
    'CONFIG_CFG80211_WEXT',
    'CONFIG_MAC80211_DEBUGFS',
    'CONFIG_MAC80211_DEBUG_MENU',
    'CONFIG_MAC80211_HWSIM',
    'CONFIG_MAC80211_MESSAGE_TRACING',
    'CONFIG_MAC80211_NOINLINE',
    'CONFIG_MAC80211_VERBOSE_DEBUG',
    'CONFIG_MAC80211_MESH',
    'CONFIG_NL80211_TESTMODE',
    'CONFIG_PCIE_DW_DEBUGFS',
    # Realtek 厂商菜单（WLAN_VENDOR_REALTEK=y）下的顶层驱动 prompt。base config
    # 里这三个显式 =n；钉死为 n 后其子驱动全部不可见，杜绝 run#5 的 RTW88 (NEW)。
    'CONFIG_RTL8XXXU',
    'CONFIG_RTW88',
    'CONFIG_RTW89',
    # Realtek 私有 "Wifi wrapper for ethernet drivers" 顶层 prompt，base =n，
    # refactor 无；不钉死则 run#6 那种 VIRT_WIFI (NEW) 阻断 syncconfig。
    'CONFIG_VIRT_WIFI',
]
# 已存在（含 =n / 注释）的行先归一：删掉旧行再追加目标值，保证唯一且为期望值
lines = text.splitlines()
keys = {w.split('=', 1)[0] for w in want} | set(unset)
lines = [l for l in lines if not any(l == k or l.startswith(k + '=') or l == '# ' + k + ' is not set' for k in keys)]
for w in want:
    lines.append(w)
for k in unset:
    lines.append('# ' + k + ' is not set')
p.write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
print('  OK   config-6.18 补齐 %d 个 PCIe/WiFi 符号 + %d 个 is-not-set' % (len(want), len(unset)))
PY

# ---- 3b. WiFi-NE 数据通路面回移植（refactor 重写 NI/FE 后整套 glue 被删）----
# RUN#16 modpost 失败根因：rtl_ax_ap 驱动引用的 rtl9617c_wifi_peer_route /
# rtl9617c_wifi_setup_tc / rtl9617c_wifi_id 三个导出符号由 base 的
# rtl9617c-wifi.c 提供，而 refactor 把 NI/FE/DMA/QM 全部重写、删除了整套
# WiFi NE glue（含 802-native-wifi-ne 的 skb.wifi_miss）。这里按 refactor
# 架构重建整条数据通路：
#   - 公共 glue rtl9617c-wifi.c（notifier + nf_hook + 3 导出符号）
#   - NI 层 6 个 rtl9617c_ni_wifi_* API + wifi[] endpoint 表
#   - DMA 层 rtl_ni_dma_xmit_wifi（下行 NE lookup 注入）
#   - QM 层 EPP wifi_id 识别 + 上行 endpoint 回调
#   - FE 层 add_wifi_port / wifi_peer_route / wifi_id 表项
# 全部替换为随资产提供的、已按 refactor 基线(ae4aeac45a70)改写的完整源文件。
NE_GLUE="$ASSETS/cu-h10/fw/board/wifi/ne-glue"
NE_DST="$KDIR/drivers/net/ethernet/realtek/rtl9617c"
[ -f "$NE_GLUE/rtl9617c-wifi.c" ] || fail "WiFi-NE glue 资产缺失：$NE_GLUE"
[ -f "$NE_GLUE/fe/fe_main.c" ] || fail "WiFi-NE FE 资产缺失"
[ -f "$NE_GLUE/ni/ni_api.c" ] || fail "WiFi-NE NI 资产缺失"
[ -f "$NE_GLUE/build/Makefile" ] || fail "WiFi-NE Makefile 资产缺失"
[ -f "$NE_GLUE/patches/820-rtl9617c-wifi-miss-skb.patch" ] || fail "WiFi-NE skbuff patch 缺失"

# 新增公共 glue + format 头（refactor 树里不存在，直接放）
cp -f "$NE_GLUE/rtl9617c-wifi.c"        "$NE_DST/rtl9617c-wifi.c"
cp -f "$NE_GLUE/rtl9617c-wifi-format.h" "$NE_DST/rtl9617c-wifi-format.h"
# 替换 NI/FE 源文件为带 WiFi 数据通路的 refactor 适配版
cp -f "$NE_GLUE/include/rtl9617c_ni.h"  "$NE_DST/rtl9617c_ni.h"
cp -f "$NE_GLUE/ni/ni.h"                "$NE_DST/ni/ni.h"
cp -f "$NE_GLUE/ni/ni_api.c"            "$NE_DST/ni/ni_api.c"
cp -f "$NE_GLUE/ni/ni_dma.c"            "$NE_DST/ni/ni_dma.c"
cp -f "$NE_GLUE/ni/ni_qm.c"             "$NE_DST/ni/ni_qm.c"
cp -f "$NE_GLUE/ni/ni_main.c"           "$NE_DST/ni/ni_main.c"
cp -f "$NE_GLUE/fe/fe.h"                "$NE_DST/fe/fe.h"
cp -f "$NE_GLUE/fe/fe_priv.h"           "$NE_DST/fe/fe_priv.h"
cp -f "$NE_GLUE/fe/fe_main.c"           "$NE_DST/fe/fe_main.c"
# Makefile / Kconfig：把 rtl9617c-wifi.o 编进 NI 模块并 select netfilter ingress
cp -f "$NE_GLUE/build/Makefile" "$NE_DST/Makefile"
cp -f "$NE_GLUE/build/Kconfig"  "$NE_DST/Kconfig"
# skbuff.h 的 wifi_miss 位域通过内核 patch 注入（OpenWrt 解压内核后自动应用）
cp -f "$NE_GLUE/patches/820-rtl9617c-wifi-miss-skb.patch" \
      "$PDIR/820-rtl9617c-wifi-miss-skb.patch"
echo "  OK   WiFi-NE 数据通路回移植（公共 glue + NI/FE/DMA/QM + skbuff patch）"

# ---- 4. 结果校验 ----
[ -f "$KDIR/drivers/pci/controller/dwc/pcie-rtl9617c.c" ] || fail "PCIe 驱动未就位"
[ -f "$KDIR/drivers/net/ethernet/realtek/rtl9617c-sgmii.h" ] || fail "PCIe SGMII 头文件未就位（phy-pcie.c 会编译失败）"
grep -q 'rtl_sgmii_link' "$KDIR/drivers/net/ethernet/realtek/rtl9617c-sgmii.h" || fail "sgmii.h 内容异常（缺 rtl_sgmii_link）"
[ -f "$WIFI_DST/pci.c" ] || fail "WiFi 驱动未就位"
grep -q '^CONFIG_PCIE_RTL9617C=y$' "$TCFG" || fail "PCIe 内核符号未写入"
grep -q '^CONFIG_RTL_AX_AP=m$' "$TCFG" || fail "WiFi 驱动内核符号 CONFIG_RTL_AX_AP=m 未写入"
grep -q 'PCIE_RTL9617C' "$PDIR/200-native-pcie.patch" || fail "PCIe patch 内容异常（缺 PCIE_RTL9617C Kconfig）"
[ -f "$PDIR/804-mac80211-rx-shortcut-state.patch" ] || fail "WiFi 基础设施 patch 804 未就位"
[ -f "$PDIR/809-native-leds.patch" ] || fail "WiFi 基础设施 patch 809 未就位"
[ -f "$KDIR/drivers/leds/leds-tyfza1.c" ] || fail "LED 控制器源文件未就位（内核会报 No rule to make leds-tyfza1.o）"
[ -f "$KDIR/drivers/leds/ledtrig-tyfza1-usb.c" ] || fail "LED USB trigger 源文件未就位"
[ -f "$KDIR/include/linux/tyfza1-led.h" ] || fail "LED 公共头未就位（linux/tyfza1-led.h）"
grep -q 'tyfza1_led_register' "$KDIR/drivers/leds/leds-tyfza1.c" || fail "leds-tyfza1.c 缺 tyfza1_led_register 导出符号"
grep -q 'struct tyfza1_led' "$KDIR/include/linux/tyfza1-led.h" || fail "tyfza1-led.h 缺 struct tyfza1_led 定义"
[ -f "$KDIR/include/linux/rtl9617c-wifi.h" ] || fail "WiFi 公共头未就位（linux/rtl9617c-wifi.h）"
grep -q 'rtl_wifi_start' "$KDIR/include/linux/rtl9617c-wifi.h" || fail "rtl9617c-wifi.h 缺 rtl_wifi_start 声明"
grep -q 'RTL9617C_NI' "$WIFI_DST/Kconfig" || fail "驱动 Kconfig 依赖未适配 refactor（RTL9617C_NI）"
# WiFi-NE 回移植校验
[ -f "$NE_DST/rtl9617c-wifi.c" ] || fail "WiFi-NE glue 未就位"
grep -q 'rtl9617c_wifi_peer_route' "$NE_DST/rtl9617c-wifi.c" || fail "WiFi-NE glue 导出符号缺失"
grep -q 'rtl_wifi_start' "$NE_DST/ni/ni_main.c" || fail "NI probe 未挂 rtl_wifi_start"
grep -q 'rtl_ni_dma_xmit_wifi' "$NE_DST/ni/ni_dma.c" || fail "NI DMA wifi 注入缺失"
grep -q 'rtl_wifi_epp_id' "$NE_DST/ni/ni_qm.c" || fail "NI QM wifi 上行分发缺失"
grep -q 'rtl_fe_add_wifi_port' "$NE_DST/fe/fe_main.c" || fail "FE wifi 表项 API 缺失"
grep -q 'rtl9617c-wifi.o' "$NE_DST/Makefile" || fail "Makefile 未编入 rtl9617c-wifi.o"
grep -q 'select NETFILTER_INGRESS' "$NE_DST/Kconfig" || fail "Kconfig 未 select NETFILTER_INGRESS"
[ -f "$PDIR/820-rtl9617c-wifi-miss-skb.patch" ] || fail "skbuff wifi_miss patch 未就位"

echo "WIFI_PCIE_OVERLAY_OK=True source_ref=refactor wifi_files=$n wifi_patches=$np ne_glue=True"
