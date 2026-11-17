#!/bin/bash
# PT1500-H10 2.5G 板级校验（独立 workflow 专用，幂等，只读断言 + 少量修补）。
#
# 2026-11-17 重大变更：源码基线从 base 20b4cf4 整体切到 upstream refactor 分支
#   （默认 HEAD b5025a9d1c95）。refactor 自带完整、实机验证的 2.5G 架构：
#     * RTL8221B HisGMII PHY 驱动（drivers/net/phy/realtek/realtek_hisgmii.c）
#     * 独立 SerDes PHY（drivers/phy/realtek/phy-rtl9617c-serdes.c）
#     * P6 lane 按协商速率重编（ni/ni_p6.c + patch 730）
#     * DTS 用 realtek,hisgmii + phy-mode=2500base-x + &serdes
#   因此本脚本【不再注入任何驱动/DTS/内核 patch】，只做校验 + 一处 WAN 默认值
#   改写（3961 -> 1101），防止上游改版悄悄回退 2.5G。
#
# base 旧基线的三步修补在 refactor 下全部作废并已删除：
#   * 移除 pt1500-fip.sh        —— refactor 树里根本没有该文件，升级走标准 fit_do_upgrade；
#   * 修 tyfza1-factory 参数     —— refactor 没有该 shell 脚本，factory 校准由驱动直读 UBI 卷
#                                   （commit b5025a9d1c9: driver is the only reader of factory volume）；
#   * CI_KERNPART=fit / zz 覆盖  —— refactor platform.sh 自带 RAMFS_COPY_BIN='fitblk fit_check_sign'
#                                   并调用 fit_do_upgrade，不需要 zz 脚本覆盖 nand_do_upgrade。
#
# 本脚本现在做四组断言 + 一处 WAN 默认值改写（任何一项不满足就 fail，编不出废固件）：
#   1. 机型定义齐全（profile / DTS / SUPPORTED_DEVICES / platform.sh 白名单）；
#   2. 2.5G 驱动与 DTS 的 hisgmii/serdes/2500base-x 特征齐全（核心，防回退到 base）；
#   3. config-6.18 的 2.5G 驱动符号齐全；
#   4. refactor 的 WAN / 首启脚本命名齐全（rtl9617c-*，不是 tyfza1-*）；
#   5. 把上游 90-pon-wan 默认 VLAN 3961 改为用户实机 XGPON 的 1101（幂等）。
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
# 驱动源码：refactor 全新拆分布局（base 的 rtl8221b-tyfza1.h 注入式已废弃）
for f in \
  "$DRV/net/phy/realtek/realtek_hisgmii.c" \
  "$DRV/net/phy/realtek/realtek_hisgmii_patch.h" \
  "$DRV/phy/realtek/phy-rtl9617c-serdes.c" \
  "$DRV/net/mdio/mdio-realtek-rtl9617c.c" \
  "$DRV/net/ethernet/realtek/rtl9617c/ni/ni_p6.c"; do
  [ -s "$f" ] || fail "refactor 2.5G 驱动文件缺失/为空：$f"
done
for p in 700-net-mdio-realtek-rtl9617c.patch 710-phy-realtek-rtl9617c-serdes.patch \
         720-net-phy-realtek-hisgmii.patch 730-net-ethernet-realtek-rtl9617c.patch; do
  [ -s "$PATCHES/$p" ] || fail "refactor 2.5G 内核补丁缺失：$p"
done
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
for sym in CONFIG_REALTEK_PHY_HISGMII CONFIG_PHY_RTL9617C_SERDES \
           CONFIG_MDIO_REALTEK_RTL9617C CONFIG_UIMAGE_FIT_BLK CONFIG_RTL9617C_NI; do
  grep -q "^${sym}=y$" "$CFG" \
    || fail "target config-6.18 缺 $sym=y（2.5G/FIT 驱动没编进内核）"
done
echo "  OK  config-6.18：HisGMII/SerDes/MDIO/UIMAGE_FIT_BLK 符号齐全"

# ---- 4. WAN / 首启脚本（refactor 命名 rtl9617c-*）----
for s in 90-pon-wan 91-pon-offload; do
  [ -f "$UCI_DIR/$s" ] || fail "refactor 上游 WAN 脚本缺失：$s"
done
# package 里的首启脚本（refactor 从 package 而非 target base-files 安装）
PKG_UCI="$WRT/package/rtl9617c"
for s in 89-rtl9617c-lan-ports 94-rtl9617c-cpu 95-rtl9617c-argon \
         96-rtl9617c-rpcd-perms 97-rtl9617c-argon-default; do
  found=0
  for f in "$PKG_UCI"/*/files/etc/uci-defaults/"$s" \
           "$PKG_UCI"/*/root/etc/uci-defaults/"$s"; do
    [ -f "$f" ] && { found=1; break; }
  done
  [ "$found" = 1 ] || fail "refactor 首启脚本缺失：$s"
done
# ---- 5. 默认 WAN VLAN 3961 -> 1101（用户实机 XGPON 默认）----
# 上游 90-pon-wan 是 EPON stock 布局（wan_vlan_default=3961，vlan_mac_offset=3）；
# 本机是 XGPON/1101 线路。编译期直接把上游默认值改成 1101，使固件第一层默认
# 就是 pon0.1101，不再只依赖 95 脚本的时序覆盖（两层保险，95 脚本仍保留，
# 负责 mtu1500 + PON FE on + LAN 统一等 H10 专属项）。
# 幂等：已是 1101 则跳过；既非 3961 也非 1101 则 fail，提示人工复核上游改版。
WAN90="$UCI_DIR/90-pon-wan"
if grep -q '^wan_vlan_default=3961$' "$WAN90"; then
  sed -i 's/^wan_vlan_default=3961$/wan_vlan_default=1101/' "$WAN90"
  sed -i 's/PPPoE on VLAN 3961/PPPoE on VLAN 1101 (H10 XGPON)/' "$WAN90" || true
fi
grep -q '^wan_vlan_default=1101$' "$WAN90" \
  || fail "90-pon-wan 默认 VLAN 既非 3961 也非 1101（上游改版？需人工复核）"
echo "  OK  首启/WAN：rtl9617c-* 命名齐全，90-pon-wan 默认 VLAN=1101（pon0.1101）"

echo "H10_BOARD_OK=True profile=$PROFILE board=$BOARD_NAME dts=$DTS baseline=refactor wan_default_vlan=1101"
