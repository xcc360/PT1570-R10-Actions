#!/bin/bash
# PT1500-H10 2.5G 专用 customize（在源码根目录、make defconfig 之前执行）。
#
# 与 R10 的 customize.sh 分开，独立 workflow 期间不改动 R10 任何文件；
# 后期合并时可把「时区 / NTP / apk 源」公共段抽到 customize-common.sh。
#
# 做四件事：
#   1. 写机型 profile / 主机名 / 默认 LAN IP
#   2. 默认时区 UTC+8 与国内 NTP
#   3. 生成 files/etc/apk/repositories.d/distfeeds.list（北大镜像）
#   4. 可选注入外部 apk 源公钥
#
# 不做：SSID/密码（本机无 WiFi）、WAN VLAN 覆盖（H10 是 EPON，沿用上游
#       90-tyfza1-pon-wan 的 pon0.3961）、root 密码、PON SN/MAC/LOID
#       （这些来自 factory 卷，由 tyfza1-factory 运行时导出）。
#
# ⚠️ 默认 LAN IP 用 192.168.2.1，不是 R10 的 192.168.1.1：
#    用户两台设备同时在线，WLAN 网关 192.168.1.1 是 PT1570-R10，
#    有线 192.168.2.1 是本机 PT1500-H10。若沿用 .1.1 两台会撞 IP，
#    且用户已按 192.168.2.0/24 配好有线直连路由与跃点数。

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

WRT_IP="${WRT_IP:-192.168.2.1}"
WRT_NAME="${WRT_NAME:-$MODEL}"
WRT_TZ="${WRT_TZ:-<+08>-8}"
WRT_ZONENAME="${WRT_ZONENAME:-Asia/Shanghai}"
WRT_NTP="${WRT_NTP:-1}"
WRT_TARGET_SUBTARGET="${WRT_TARGET_SUBTARGET:-rtl9617c/generic}"
WRT_ARCH_PACKAGES="${WRT_ARCH_PACKAGES:-aarch64_cortex-a55}"
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
# 本 target 编译架构 aarch64_cortex-a55，北大镜像只有 aarch64_cortex-a53 目录；
# a53/a55 同属 armv8-a，用户态通用。公钥由 files-h10/etc/apk/keys/ 注入。
WRT_APK_MIRROR="${WRT_APK_MIRROR:-https://mirrors.pku.edu.cn/immortalwrt}"
WRT_APK_RELEASE="${WRT_APK_RELEASE:-25.12-SNAPSHOT}"
WRT_APK_REPO_ARCH="${WRT_APK_REPO_ARCH:-aarch64_cortex-a53}"

mkdir -p files/etc/apk/repositories.d
if [ "$WRT_APK_MIRROR" = "none" ] || [ "$WRT_APK_MIRROR" = "off" ]; then
  {
    echo "# 由 customize-h10.sh 生成：不启用外部 apk 源"
  } > files/etc/apk/repositories.d/distfeeds.list
elif [ -n "${APK_MIRROR_BASE:-}" ]; then
  BASE="${APK_MIRROR_BASE%/}"
  {
    echo "# 由 customize-h10.sh 生成：APK_MIRROR_BASE 显式指定"
    echo "$BASE/targets/$WRT_TARGET_SUBTARGET/packages/packages.adb"
    for feed in $WRT_APK_FEEDS; do
      echo "$BASE/packages/$WRT_ARCH_PACKAGES/$feed/packages.adb"
    done
  } > files/etc/apk/repositories.d/distfeeds.list
else
  MK="${WRT_APK_MIRROR%/}/releases/$WRT_APK_RELEASE/packages/$WRT_APK_REPO_ARCH"
  {
    echo "# 由 customize-h10.sh 生成：北大镜像 immortalwrt $WRT_APK_RELEASE"
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

# 不追加 Config-EXTRA.txt：R10 的用户软件包基线（tailscale 三件套 +
# kmod-tun + zh_Hans）已直接写入 Config-PT1500-H10.txt，避免重复与耦合。
