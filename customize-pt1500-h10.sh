#!/bin/bash
# PT1500-H10 2.5G 专用 customize（在源码根目录、make defconfig 之前执行）。
#
# 与 R10 的 customize-pt1570-r10.sh 分开，独立 workflow 期间不改动 R10 任何文件；
# 后期合并时可把「时区 / NTP / apk 源」公共段抽到 customize-common.sh。
#
# 做四件事：
#   1. 写机型 profile / 主机名 / 默认 LAN IP
#   2. 默认时区 UTC+8 与国内 NTP
#   3. 生成 files/etc/apk/repositories.d/distfeeds.list（北大镜像）
#   4. 可选注入外部 apk 源公钥
#
# 不做：SSID/密码（本机无 WiFi）、root 密码、PON SN/MAC/LOID
#       （这些来自 factory 卷，由 refactor 的 pon-control 运行时导出）。
# 2026-11-17 基线切到 refactor：源码用 upstream 的 90-pon-wan / 91-pon-offload，
#       架构为 aarch64_cortex-a53（不再是 base 的 a55）。
# WAN 默认值不在这里改：由 files-h10/etc/uci-defaults/95-pt1500-h10-wan-default
#       在 90/91 之后覆盖。refactor 的 90-pon-wan 默认 EPON VLAN 3961；
#       PT1500 实机（XGPON/1101 线路）需要 1101 + PON FE，由该脚本覆盖。
#
# 三机型统一默认 LAN IP = 192.168.1.1（2026-11-15 用户要求）。
#    PT1570-R10 / PT1570-H10-CU / PT1500-H10 全部改成 192.168.1.1/24。
#    注意：三台同时接在同一台 PC 的同一网段时会撞 IP，调试时只接一台，
#    或按 MAC 绑定网卡区分；首启脚本 95-pt1500-h10-wan-default 会把
#    旧值（192.168.2.1 / 192.168.18.1）迁移到 192.168.1.1/24 并补 /24 掩码，
#    避免 sysupgrade 保留旧配置后 netifd 按 /32 配址、dnsmasq 不发 DHCPv4。

set -euo pipefail

if [ ! -f package/base-files/files/bin/config_generate ]; then
  for d in wrt "${GITHUB_WORKSPACE:-}/wrt" "${GITHUB_WORKSPACE:-}"; do
    [ -n "$d" ] || continue
    if [ -f "$d/package/base-files/files/bin/config_generate" ]; then cd "$d"; break; fi
  done
fi
if [ ! -f package/base-files/files/bin/config_generate ]; then
  echo "WARN: 未找到 OpenWrt 源码根，跳过默认设置改写" >&2
  exit 0
fi

PROFILE="youhua_pt1500_h10_2p5g"
MODEL="PT1500-H10"

WRT_IP="${WRT_IP:-192.168.1.1}"
WRT_NAME="${WRT_NAME:-$MODEL}"
WRT_TZ="${WRT_TZ:-<+08>-8}"
WRT_ZONENAME="${WRT_ZONENAME:-Asia/Shanghai}"
WRT_NTP="${WRT_NTP:-1}"
WRT_TARGET_SUBTARGET="${WRT_TARGET_SUBTARGET:-rtl9617c/generic}"
# refactor 编译架构 aarch64_cortex-a53（CPU_TYPE=cortex-a53），与北大镜像
# immortalwrt 25.12 的 aarch64_cortex-a53 目录正好一致，无需再补 a53。
WRT_ARCH_PACKAGES="${WRT_ARCH_PACKAGES:-aarch64_cortex-a53}"
WRT_APK_FEEDS="${WRT_APK_FEEDS:-base luci packages routing telephony}"

CFG="package/base-files/files/bin/config_generate"

# ---- 1. 机型 profile ----
grep -q "^CONFIG_TARGET_rtl9617c_generic_DEVICE_${PROFILE}=y$" .config || \
  echo "CONFIG_TARGET_rtl9617c_generic_DEVICE_${PROFILE}=y" >> .config
sed -i "/^CONFIG_TARGET_PROFILE=/d" .config
echo "CONFIG_TARGET_PROFILE=\"DEVICE_${PROFILE}\"" >> .config
echo "customize-h10: board=pt1500-h10-2p5g profile=$PROFILE"

sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG"
sed -i "s|set system\.@system\[-1\]\.hostname='[^']*'|set system.@system[-1].hostname='$WRT_NAME'|" "$CFG"
echo "customize-h10: IP=$WRT_IP hostname=$WRT_NAME"

# ---- 2. 时区 + 国内 NTP ----
sed -i "s|timezone='[^']*'|timezone='$WRT_TZ'|" "$CFG"
sed -i "s|zonename='[^']*'|zonename='$WRT_ZONENAME'|" "$CFG"
echo "customize-h10: timezone=$WRT_TZ zonename=$WRT_ZONENAME"

if [ "$WRT_NTP" = "1" ]; then
  sed -i \
    -e "s|time\.apple\.com|ntp.aliyun.com|g" \
    -e "s|time1\.google\.com|time1.cloud.tencent.com|g" \
    -e "s|time\.cloudflare\.com|ntp.ntsc.ac.cn|g" \
    -e "s|pool\.ntp\.org|cn.pool.ntp.org|g" "$CFG"
  echo "customize-h10: NTP -> 国内源"
fi

# ---- 3. apk 源（沿用 R10 基线：北大镜像 immortalwrt 25.12-SNAPSHOT）----
# refactor 编译架构 aarch64_cortex-a53，与北大镜像 aarch64_cortex-a53 目录一致。
# 公钥由 files-h10/etc/apk/keys/ 注入。
WRT_APK_MIRROR="${WRT_APK_MIRROR:-https://mirrors.pku.edu.cn/immortalwrt}"
WRT_APK_RELEASE="${WRT_APK_RELEASE:-25.12-SNAPSHOT}"
WRT_APK_REPO_ARCH="${WRT_APK_REPO_ARCH:-aarch64_cortex-a53}"

mkdir -p files/etc/apk/repositories.d
if [ "$WRT_APK_MIRROR" = "none" ] || [ "$WRT_APK_MIRROR" = "off" ]; then
  {
    echo "# 由 customize-pt1500-h10.sh 生成：不启用外部 apk 源"
  } > files/etc/apk/repositories.d/distfeeds.list
elif [ -n "${APK_MIRROR_BASE:-}" ]; then
  BASE="${APK_MIRROR_BASE%/}"
  {
    echo "# 由 customize-pt1500-h10.sh 生成：APK_MIRROR_BASE 显式指定"
    echo "$BASE/targets/$WRT_TARGET_SUBTARGET/packages/packages.adb"
    for feed in $WRT_APK_FEEDS; do
      echo "$BASE/packages/$WRT_ARCH_PACKAGES/$feed/packages.adb"
    done
  } > files/etc/apk/repositories.d/distfeeds.list
else
  MK="${WRT_APK_MIRROR%/}/releases/$WRT_APK_RELEASE/packages/$WRT_APK_REPO_ARCH"
  {
    echo "# 由 customize-pt1500-h10.sh 生成：北大镜像 immortalwrt $WRT_APK_RELEASE"
    echo "# 本机架构 $WRT_ARCH_PACKAGES；镜像无该目录，改用 $WRT_APK_REPO_ARCH"
    echo "# 索引公钥 /etc/apk/keys/immortalwrt-25.12.pem"
    echo "# kmod-* 别从镜像装（内核版本不同），用同批 packages"
    for feed in $WRT_APK_FEEDS; do
      echo "$MK/$feed/packages.adb"
    done
  } > files/etc/apk/repositories.d/distfeeds.list
fi
echo "customize-h10: wrote distfeeds.list"
sed 's/^/    /' files/etc/apk/repositories.d/distfeeds.list

# ---- 4. 可选外部 apk 公钥 ----
if [ -n "${APK_REPO_KEY_URL:-}" ]; then
  mkdir -p files/etc/apk/keys
  if curl -fsSL --max-time 60 "$APK_REPO_KEY_URL" \
      -o files/etc/apk/keys/external-repo.pem; then
    echo "customize-h10: external apk repo key injected"
  else
    echo "WARN: apk 公钥下载失败，跳过" >&2
    rm -f files/etc/apk/keys/external-repo.pem
  fi
fi

# 不追加 Config-PT1570-R10-extra.txt：R10 的用户软件包基线（tailscale 三件套 +
# kmod-tun + zh_Hans）已直接写入 Config-PT1500-H10.txt，避免重复与耦合。
