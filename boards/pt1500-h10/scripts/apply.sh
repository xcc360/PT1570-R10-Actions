#!/bin/bash
# PT1500-H10 2.5G 板级校验（独立 workflow 专用，幂等，只读断言 + 少量修补）。
#
# ★★★ 2026-11-17 第二次基线升级：refactor HEAD b5025a9d1c95 -> 659700cc1bbc ★★★
#   上游 4 个新提交：659700cc1bbc (harden OMCI handling and PON bring-up)、
#   f076437fb4d5 (hand flow offload back to firewall)、以及两个 revert。
#   2.5G 架构**零变化**（HisGMII / SerDes PHY / 2500base-x 全部原位），
#   且 run#6 已实机确认 2.5G 可用。升级同时修了两个实机问题：
#
#   【问题 1】面板灯全错 —— 上游 DTS 的 leds GPIO 编号没按原厂 bank 换算。
#     原厂 DTB 是 5 个 bank（面板灯分布在 bank0 与 bank3），上游 refactor 合并成
#     单个扁平 gpio0 后，PT1500 DTS 沿用了另一套编号，8 个灯错 7 个。
#     → 本脚本第 6 组调用 apply-dts-leds-fix.sh 按原厂 DTB 覆盖。
#
#   【问题 2】XGPON 认证失败、LuCI 报"设备初始化失败" —— 上游 config/pon 硬编码
#     `option mode 'epon-d10g'`（PT1500 EPON profile），而本机走 XGPON 线路。
#     驱动按 mode 选 serdes 表并分流 offload 路径，走错分支则 OMCI 通道不建立。
#     → 本脚本第 5 组把上游默认值直接纠正为 xgpon；
#       95-pt1500-h10-wan-default 也在首启时二次纠正（防 sysupgrade 保留旧配置）。
#
#   上游在本次重构中删除了 90-pon-wan / 91-pon-offload / 89-rtl9617c-lan-ports /
#   97-rtl9617c-argon-default（WAN provisioning 收进 Rust pon daemon，offload
#   交回 firewall，89 只是 rename-netdevs.uc 的包装脚本）。因此：
#     * WAN / VLAN / PPPoE / PON FE 全部改由 files-h10 的 95 脚本负责；
#     * 断言改为「校验仍存在的 + 反向校验已删的确实不存在」，防上游改版时我们
#       基于旧假设写出错误的注入逻辑。
#
# 历史变更（2026-11-17 第一次）：源码基线从 base 20b4cf4 整体切到 refactor 分支。
#   refactor 自带完整、实机验证的 2.5G 架构：
#     * RTL8221B HisGMII PHY 驱动（drivers/net/phy/realtek/realtek_hisgmii.c）
#     * 独立 SerDes PHY（Taurus: phy-taurus-serdes.c + phy-taurus-lane.c；
#       旧 refactor: phy-rtl9617c-serdes.c）
#     * P6 lane 按协商速率重编（ni/ni_p6.c + patch 730）
#     * DTS 用 realtek,hisgmii + phy-mode=2500base-x + &serdes
# base 旧基线的三步修补在 refactor 下全部作废：
#   * 移除 pt1500-fip.sh        —— refactor 树里根本没有该文件，升级走标准 fit_do_upgrade；
#   * 修 tyfza1-factory 参数     —— refactor 没有该 shell 脚本，factory 校准由驱动直读 UBI 卷
#                                   （commit b5025a9d1c9: driver is the only reader of factory volume）；
#   * CI_KERNPART=fit / zz 覆盖  —— refactor platform.sh 自带 RAMFS_COPY_BIN='fitblk fit_check_sign'
#                                   并调用 fit_do_upgrade，不需要 zz 脚本覆盖 nand_do_upgrade。
#
# 本脚本现在做六组断言 + 三处修补（任何一项不满足就 fail，编不出废固件）：
#   1. 机型定义齐全（profile / DTS / SUPPORTED_DEVICES / platform.sh 白名单）；
#   2. 2.5G 驱动与 DTS 的 hisgmii/serdes/2500base-x 特征齐全（核心，防回退到 base）；
#   3. config-6.18 的 2.5G 驱动符号齐全；
#   4. refactor 首启脚本齐全 + 被删脚本确实已删（防上游改版导致逻辑打架）；
#   5. 上游 pon config 的 mode 纠正为 xgpon + 确认上游 WAN 脚本未复活；
#   6. DTS 面板灯按原厂 DTB flat 编号覆盖。
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
PLATFORM="$WRT/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh"
CFG="$WRT/target/linux/rtl9617c/config-6.18"
DRV="$WRT/target/linux/rtl9617c/files-6.18/drivers"
PATCHES="$WRT/target/linux/rtl9617c/patches-6.18"
UCI_DIR="$WRT/target/linux/rtl9617c/base-files/etc/uci-defaults"

# ---- 1. 机型定义齐全 ----
grep -q "^define Device/${PROFILE}$" "$IMG_MK" \
  || fail "上游 image/Makefile 缺少 Device/${PROFILE}"
grep -q "SUPPORTED_DEVICES += ${BOARD_NAME}" "$IMG_MK" \
  || fail "上游 image/Makefile 缺少 SUPPORTED_DEVICES += ${BOARD_NAME}"
grep -q "DEVICE_DTS := ${DTS}" "$IMG_MK" \
  || fail "上游 image/Makefile 的 DEVICE_DTS 不是 ${DTS}"
[ -f "$DTS_FILE" ] || fail "上游 DTS 缺失：$DTS_FILE"
grep -q "compatible = \"${BOARD_NAME}\"" "$DTS_FILE" \
  || fail "上游 DTS 的 compatible 与 $BOARD_NAME 不一致"
grep -q "${BOARD_NAME}" "$PLATFORM" \
  || fail "platform.sh 白名单缺少 ${BOARD_NAME}"
grep -q 'fit_do_upgrade' "$PLATFORM" \
  || fail "platform.sh 未走标准 fit_do_upgrade（refactor 基线特征）"
grep -q 'volname = "fit"' "$DTS_FILE" \
  || fail "DTS 缺少 volname=fit 的 UBI 卷"
echo "  OK  机型定义：profile=$PROFILE board=$BOARD_NAME dts=$DTS"

# ---- 2. 2.5G 驱动与 DTS 特征（核心，防回退到 base 旧架构）----
# 驱动源码：2026-11-21 上游 Taurus 重构后 serdes/mdio 驱动与补丁改名；
# 保留旧 refactor 文件名做兼容，便于临时回退 source_ref 时仍能校验。
for f in \
  "$DRV/net/phy/realtek/realtek_hisgmii.c" \
  "$DRV/net/phy/realtek/realtek_hisgmii_patch.h" \
  "$DRV/net/ethernet/realtek/rtl9617c/ni/ni_p6.c"; do
  [ -s "$f" ] || fail "2.5G 驱动文件缺失/为空：$f"
done
TAURUS=0
if [ -s "$DRV/phy/realtek/phy-taurus-serdes.c" ]; then
  TAURUS=1
  for f in "$DRV/phy/realtek/phy-taurus-serdes.c" \
           "$DRV/phy/realtek/phy-taurus-lane.c" \
           "$DRV/net/mdio/mdio-realtek-taurus.c"; do
    [ -s "$f" ] || fail "Taurus 2.5G 驱动文件缺失/为空：$f"
  done
else
  for f in "$DRV/phy/realtek/phy-rtl9617c-serdes.c" \
           "$DRV/net/mdio/mdio-realtek-rtl9617c.c"; do
    [ -s "$f" ] || fail "refactor 2.5G 驱动文件缺失/为空：$f"
  done
fi
for p in 720-net-phy-realtek-hisgmii.patch 730-net-ethernet-realtek-rtl9617c.patch; do
  [ -s "$PATCHES/$p" ] || fail "2.5G 内核补丁缺失：$p"
done
if [ "$TAURUS" = 1 ]; then
  for p in 700-net-mdio-realtek-taurus.patch 710-phy-realtek-taurus-serdes.patch; do
    [ -s "$PATCHES/$p" ] || fail "Taurus 2.5G 内核补丁缺失：$p"
  done
  BASELINE=taurus
else
  for p in 700-net-mdio-realtek-rtl9617c.patch 710-phy-realtek-rtl9617c-serdes.patch; do
    [ -s "$PATCHES/$p" ] || fail "refactor 2.5G 内核补丁缺失：$p"
  done
  BASELINE=refactor
fi
# DTS：2.5G 口（phy@6）必须是 hisgmii + serdes-option-mode，NI port@6 走 2500base-x
for kw in 'realtek,hisgmii' 'realtek,serdes-option-mode' 'phy-mode = "2500base-x"' \
          'ethernet-phy@6' 'port@6' 'phys = <&serdes>' '&serdes'; do
  grep -qF "$kw" "$DTS_FILE" \
    || fail "DTS 缺 2.5G 特征 '$kw'（可能回退到 base 架构，2.5G 不会 link）"
done
# 反向：refactor 不应再有 base 的 2.5G 特征（出现即说明基线串了）
for kw in 'realtek,hsgmii' 'realtek,p6-phy' 'fpga-image@10000' 'p6-serdes'; do
  grep -qF "$kw" "$DTS_FILE" \
    && fail "DTS 残留 base 旧架构特征 '$kw'（基线可能被串回 20b4cf4）" || true
done
[ ! -d "$WRT/target/linux/rtl9617c/base-files/etc/serdes" ] \
  || fail "残留 base 的 /etc/serdes/*.txt（refactor 用内建 patch data，不该有此目录）"
echo "  OK  2.5G 架构：HisGMII + SerDes PHY + 2500base-x + patch 700-730 齐全"

# ---- 3. config-6.18 的 2.5G 驱动符号 ----
if [ "$TAURUS" = 1 ]; then
  for sym in CONFIG_REALTEK_PHY_HISGMII CONFIG_RTL9617C_NI CONFIG_UIMAGE_FIT_BLK \
             CONFIG_PHY_REALTEK_TAURUS_SERDES CONFIG_PHY_REALTEK_TAURUS_LANE \
             CONFIG_MDIO_REALTEK_TAURUS; do
    grep -q "^${sym}=y$" "$CFG" \
      || fail "target config-6.18 缺 $sym=y（Taurus 2.5G 驱动没编进内核）"
  done
else
  for sym in CONFIG_REALTEK_PHY_HISGMII CONFIG_PHY_RTL9617C_SERDES \
             CONFIG_MDIO_REALTEK_RTL9617C CONFIG_UIMAGE_FIT_BLK CONFIG_RTL9617C_NI; do
    grep -q "^${sym}=y$" "$CFG" \
      || fail "target config-6.18 缺 $sym=y（2.5G/FIT 驱动没编进内核）"
  done
fi
echo "  OK  config-6.18：HisGMII/SerDes/MDIO/UIMAGE_FIT_BLK 符号齐全（$BASELINE）"

# ---- 4. 首启脚本（refactor 命名 rtl9617c-*）----
# ★ 2026-11-17：基线从 b5025a9d1c95 升到 659700cc1bbc 后，上游重构了首启脚本：
#   * 89-rtl9617c-lan-ports：**形态变了但没删**。旧 HEAD 是「shell 包装脚本 +
#     单独装 rename-netdevs.uc」，新 HEAD 改成 Makefile 直接
#     INSTALL_BIN ./files/usr/share/rtl9617c/rename-netdevs.uc
#       -> $(1)/etc/uci-defaults/89-rtl9617c-lan-ports
#     即 89 脚本本身就是 ucode 程序，功能等价。
#     （这一点由 RUN #8 的镜像校验实测纠正：一度误判它被删，反向断言导致失败。）
#   * 删除 97-rtl9617c-argon-default
#   * 删除 90-pon-wan / 91-pon-offload（WAN provisioning 收进 Rust pon daemon，
#     offload 交回 firewall）—— 见第 5 组，WAN/VLAN 改由我们的 95 脚本负责。
# 因此这里的断言改为「校验仍然存在的那些 + 校验被删的那些确实不存在」，
# 防止上游改版时我们基于旧假设写出错误的注入逻辑。
PKG_UCI="$WRT/package/rtl9617c"
for s in 94-rtl9617c-cpu 95-rtl9617c-argon 96-rtl9617c-rpcd-perms; do
  found=0
  for f in "$PKG_UCI"/*/files/etc/uci-defaults/"$s" \
           "$PKG_UCI"/*/root/etc/uci-defaults/"$s"; do
    [ -f "$f" ] && { found=1; break; }
  done
  [ "$found" = 1 ] || fail "refactor 首启脚本缺失：$s"
done
# rename-netdevs.uc 本体必须还在（网卡重命名靠它）
found=0
for f in "$PKG_UCI"/*/files/usr/share/rtl9617c/rename-netdevs.uc; do
  [ -f "$f" ] && { found=1; break; }
done
[ "$found" = 1 ] || fail "refactor rename-netdevs.uc 缺失（网卡重命名会失效）"
# 89-rtl9617c-lan-ports：新 HEAD 里它就是 rename-netdevs.uc 本体，
# 由 Makefile 的 install 段直接装到 $(1)/etc/uci-defaults/89-rtl9617c-lan-ports。
# 注意：源码树里【没有】这个文件（它不是 files/etc/uci-defaults/ 下的静态文件），
# 所以只能校验 Makefile 的安装规则 —— RUN #9 实测纠正：误查源码树导致误报缺失。
MK="$PKG_UCI/rtl9617c-pon-control/Makefile"
[ -f "$MK" ] || fail "refactor 缺少 rtl9617c-pon-control/Makefile"
grep -q '89-rtl9617c-lan-ports' "$MK" \
  || fail "refactor 的 pon-control Makefile 不再安装 89-rtl9617c-lan-ports（网卡重命名会失效）"
grep -q 'rename-netdevs.uc' "$MK" \
  || fail "refactor 的 pon-control Makefile 不再安装 rename-netdevs.uc"
# pon-leds 服务与 ucode 助手必须在（面板 LOS/PON 灯由它按 label 名驱动）
[ -f "$PKG_UCI/rtl9617c-pon-control/files/etc/init.d/pon-leds" ] \
  || fail "refactor pon-leds 服务缺失"
[ -f "$PKG_UCI/rtl9617c-pon-control/files/pon-leds.uc" ] \
  || fail "refactor pon-leds.uc 缺失（LOS/PON 灯不会被驱动）"

# ---- 5. PON mode 纠正为 xgpon + WAN VLAN 1101 ----
# ★ 2026-11-17 实机回归：XGPON 认证失败、LuCI 报"设备初始化失败"。
#   根因：上游 refactor 的 package/rtl9617c/rtl9617c-pon-control/files/etc/config/pon
#   硬编码 `option mode 'epon-d10g'`（PT1500 的 EPON profile），
#   而本机实机走 XGPON 线路（原厂 mtd4 内多处 WanType=XGPON 佐证）。
#   驱动侧后果：pon_serdes.c 按 mode 选 serdes 表（epon_d10g vs xgpon），
#   init.d/pon 的 offload 分支也按 mode 分流（EPON 写 traffic/mpcp，
#   XGPON 才写 activation/pon-omci）-> OMCI 通道不建立 -> OLT 等不到注册。
#   这里在编译期直接纠正上游默认值，使固件第一层默认就是 xgpon。
PON_CONF="$PKG_UCI/rtl9617c-pon-control/files/etc/config/pon"
[ -f "$PON_CONF" ] || fail "refactor pon 配置缺失：$PON_CONF"
if grep -q "^[[:space:]]*option mode 'epon-d10g'$" "$PON_CONF"; then
  sed -i "s/^\([[:space:]]*\)option mode 'epon-d10g'$/\1option mode 'xgpon'/" "$PON_CONF"
fi
grep -q "^[[:space:]]*option mode 'xgpon'$" "$PON_CONF" \
  || fail "pon config 的 mode 既非 epon-d10g 也非 xgpon（上游改版？需人工复核）"
echo "  OK  PON mode：上游 epon-d10g 已纠正为 xgpon（本机为 XGPON 线路）"

# WAN / VLAN：上游 90-pon-wan 已被删除（WAN provisioning 收进 Rust daemon），
# 我们不再 patch 上游默认值，而是完全由 files-h10 的 95 脚本负责：
#   VLAN 1101 + 8021q 子设备（mtu 1500）+ PPPoE + PON FE on + LAN 统一。
# 这里只做「确保上游确实没有 90-pon-wan（避免两套 WAN 逻辑打架）」的反向断言，
# 以及校验我们的 95 脚本确实带了关键项。
[ ! -f "$UCI_DIR/90-pon-wan" ] \
  || fail "上游 90-pon-wan 复活了（WAN provisioning 又回到 shell？）需复核两套逻辑是否冲突"
[ ! -f "$UCI_DIR/91-pon-offload" ] \
  || fail "上游 91-pon-offload 复活了（offload 策略又变？）需复核"

# ---- 6. DTS 面板灯按原厂 DTB 校准 ----
# 上游 PT1500 DTS 的 leds 用的是未按原厂 bank 换算的编号（8 个灯错 7 个），
# 实机表现为"指示灯完全不对"。这里调用注入脚本按原厂 DTB 换算后覆盖。
LED_SCRIPT="$ASSETS/scripts/apply-dts-leds-fix.sh"
[ -f "$LED_SCRIPT" ] || fail "缺 DTS 灯校正脚本：$LED_SCRIPT"
bash "$LED_SCRIPT" "$WRT" "$DTS"
echo "  OK  面板灯：已按 run#17 实机定 pin 覆盖（10 盏，电源11/光纤9/光信号10/宽带2/电话12/未标记1=7/千兆4=0/千兆3=1/iTV=3/未标记2=6；2.5G口无GPIO）"

# ---- upstream drift: drop unavailable diagnostic packages from profile ----
# Current OpenWrt packages feed no longer provides tc, and these three are not
# auto-selected by defconfig. Upstream Device/... still lists them in
# DEVICE_PACKAGES, so strip them before defconfig builds Target-Profile-Packages.
sed -i -E 's/(^|[[:space:]])(tc|mtr|conntrack-tools)([[:space:]]|$)/ /g' "$IMG_MK"
! grep -qE '[[:space:]](tc|mtr|conntrack-tools)([[:space:]]|$)' "$IMG_MK" \
  || fail "diagnostic packages still in image/Makefile after strip"
echo "  OK  profile diagnostics stripped: tc mtr conntrack-tools"

echo "H10_BOARD_OK=True profile=$PROFILE board=$BOARD_NAME dts=$DTS baseline=$BASELINE pon_mode=xgpon wan_default_vlan=1101"
