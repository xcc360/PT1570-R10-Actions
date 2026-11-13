#!/bin/bash
# 在源码根目录执行（Configure 步骤中，make defconfig 之前）。
#
# 做五件事：
#   1. 按 PT1570_BOARD 写机型专属 profile / 主机名 / 默认 IP / SSID
#   2. 默认时区 UTC+8（Asia/Shanghai）与国内 NTP
#   3. 生成 files/etc/apk/repositories.d/distfeeds.list
#   4. 可选注入外部 apk 源公钥
#   5. 追加仓库根 Config-EXTRA.txt（可选额外软件包）
#
# 当前范围：R10-only（H10 暂缓），但保留按机型选择参数的骨架。
#
# ⚠️ 与 HG5585F-CT 路线 B 的关键差异：
#      本 target 的 CPU_TYPE=cortex-a55，架构包目录是 aarch64_cortex-a55，
#      而国内 immortalwrt 镜像（含北大）只提供 aarch64_cortex-a53 目录。
#      a53/a55 同属 armv8-a，用户态通用，故 distfeeds 默认指向镜像的 a53 目录，
#      并随镜像带上 immortalwrt 25.12 索引公钥（否则 apk 报 UNTRUSTED signature）。
#      镜像目录写死版本（25.12-SNAPSHOT），可用 WRT_APK_MIRROR/WRT_APK_RELEASE
#      覆盖，或设 WRT_APK_MIRROR=none 关掉外部源。

set -euo pipefail

# ---- 定位源码根目录 ----
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

# 2026-11-09 起为 R10-only；H10 资产保留但默认禁止产出固件。
BOARD="${PT1570_BOARD:-r10}"
case "$BOARD" in
  r10) PROFILE="youhua_pt1570_r10"; MODEL="PT1570-R10" ;;
  h10)
    [ "${PT1570_ALLOW_H10:-0}" = "1" ] || {
      echo "ERROR: PT1570-H10 已暂缓，当前范围是 R10-only" >&2; exit 1; }
    PROFILE="youhua_pt1570_h10"; MODEL="PT1570-H10" ;;
  *)   echo "ERROR: PT1570_BOARD must be r10 (R10-only scope)" >&2; exit 1 ;;
esac

WRT_IP="${WRT_IP:-192.168.1.1}"
WRT_NAME="${WRT_NAME:-$MODEL}"
WRT_SSID="${WRT_SSID:-$MODEL}"
WRT_WORD="${WRT_WORD:-12345678}"
WRT_TZ="${WRT_TZ:-<+08>-8}"
WRT_ZONENAME="${WRT_ZONENAME:-Asia/Shanghai}"
WRT_NTP="${WRT_NTP:-1}"
WRT_TARGET_SUBTARGET="${WRT_TARGET_SUBTARGET:-rtl9617c/generic}"
WRT_ARCH_PACKAGES="${WRT_ARCH_PACKAGES:-aarch64_cortex-a55}"
WRT_APK_FEEDS="${WRT_APK_FEEDS:-base luci packages routing telephony}"

CFG="package/base-files/files/bin/config_generate"
WIFI_UC="package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"

# ---- 1. 机型 profile（写在 customize 阶段，两次 defconfig 后会再断言） ----
grep -q "^CONFIG_TARGET_rtl9617c_generic_DEVICE_${PROFILE}=y$" .config || \
  echo "CONFIG_TARGET_rtl9617c_generic_DEVICE_${PROFILE}=y" >> .config
sed -i "/^CONFIG_TARGET_PROFILE=/d" .config
echo "CONFIG_TARGET_PROFILE=\"DEVICE_${PROFILE}\"" >> .config
echo "customize: board=$BOARD profile=$PROFILE"

sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG"
sed -i "s|set system\.@system\[-1\]\.hostname='[^']*'|set system.@system[-1].hostname='$WRT_NAME'|" "$CFG"
echo "customize: IP=$WRT_IP hostname=$WRT_NAME"

if [ -f "$WIFI_UC" ]; then
  sed -i "s/ssid '.*'/ssid '$WRT_SSID'/g; s/key '.*'/key '$WRT_WORD'/g" "$WIFI_UC"
  echo "customize: SSID=$WRT_SSID"
else
  echo "customize: wifi-scripts mac80211.uc not found, skip SSID" >&2
fi

# ---- 2. 时区 + 国内 NTP ----
sed -i "s|timezone='[^']*'|timezone='$WRT_TZ'|" "$CFG"
sed -i "s|zonename='[^']*'|zonename='$WRT_ZONENAME'|" "$CFG"
echo "customize: timezone=$WRT_TZ zonename=$WRT_ZONENAME"

if [ "$WRT_NTP" = "1" ]; then
  sed -i \
    -e "s|time\.apple\.com|ntp.aliyun.com|g" \
    -e "s|time1\.google\.com|time1.cloud.tencent.com|g" \
    -e "s|time\.cloudflare\.com|ntp.ntsc.ac.cn|g" \
    -e "s|pool\.ntp\.org|cn.pool.ntp.org|g" "$CFG"
  echo "customize: NTP -> 国内源"
fi

# ---- 3. apk 源（默认：北大镜像 immortalwrt 25.12-SNAPSHOT） ----
# 三个事实（2026-11-13 真机核实）：
#   a) 本 target 编译架构是 aarch64_cortex-a55，但北大镜像（含国内其它镜像）
#      releases/<ver>/packages/ 下只有 aarch64_cortex-a53 目录，没有 a55。
#      a53/a55 同属 armv8-a，用户态二进制通用；镜像里 /etc/apk/arch 已同时
#      列了 a55 和 a53，因此指到 a53 目录是能装能跑的（apk add 已实测）。
#   b) 镜像索引由 immortalwrt 25.12 发布密钥签名。缺公钥时 apk 会打印
#      "WARNING: ... UNTRUSTED signature" 并整份丢弃索引（只剩本机包）。
#      公钥随镜像走：files/etc/apk/keys/immortalwrt-25.12.pem。
#   c) kmod-* 与本机内核版本/配置强绑定，绝不要从镜像装，用同批 packages。
WRT_APK_MIRROR="${WRT_APK_MIRROR:-https://mirrors.pku.edu.cn/immortalwrt}"
WRT_APK_RELEASE="${WRT_APK_RELEASE:-25.12-SNAPSHOT}"
WRT_APK_REPO_ARCH="${WRT_APK_REPO_ARCH:-aarch64_cortex-a53}"

mkdir -p files/etc/apk/repositories.d
if [ "$WRT_APK_MIRROR" = "none" ] || [ "$WRT_APK_MIRROR" = "off" ]; then
  {
    echo "# 由 customize.sh 生成：WRT_APK_MIRROR=$WRT_APK_MIRROR，不启用外部源。"
    echo "# 配套内核模块与用户态包请用同批 packages（customfeeds.list）。"
  } > files/etc/apk/repositories.d/distfeeds.list
elif [ -n "${APK_MIRROR_BASE:-}" ]; then
  BASE="${APK_MIRROR_BASE%/}"
  {
    echo "# 由 customize.sh 生成：APK_MIRROR_BASE 显式指定，请自行确认路径存在。"
    echo "$BASE/targets/$WRT_TARGET_SUBTARGET/packages/packages.adb"
    for feed in $WRT_APK_FEEDS; do
      echo "$BASE/packages/$WRT_ARCH_PACKAGES/$feed/packages.adb"
    done
  } > files/etc/apk/repositories.d/distfeeds.list
else
  MK="${WRT_APK_MIRROR%/}/releases/$WRT_APK_RELEASE/packages/$WRT_APK_REPO_ARCH"
  {
    echo "# 由 customize.sh 生成：北大镜像 immortalwrt $WRT_APK_RELEASE"
    echo "# 本机架构 $WRT_ARCH_PACKAGES；镜像无该目录，改用 $WRT_APK_REPO_ARCH（同 armv8-a）"
    echo "# 索引公钥 /etc/apk/keys/immortalwrt-25.12.pem，缺则报 UNTRUSTED signature"
    echo "# kmod-* 别从镜像装（内核版本不同），用同批 packages"
    for feed in $WRT_APK_FEEDS; do
      echo "$MK/$feed/packages.adb"
    done
  } > files/etc/apk/repositories.d/distfeeds.list
fi
echo "customize: wrote distfeeds.list"
sed 's/^/    /' files/etc/apk/repositories.d/distfeeds.list

# ---- 4. 可选外部 apk 公钥 ----
if [ -n "${APK_REPO_KEY_URL:-}" ]; then
  mkdir -p files/etc/apk/keys
  if curl -fsSL --max-time 60 "$APK_REPO_KEY_URL" \
      -o files/etc/apk/keys/external-repo.pem; then
    echo "customize: external apk repo key injected"
  else
    echo "WARN: apk 公钥下载失败，跳过" >&2
    rm -f files/etc/apk/keys/external-repo.pem
  fi
fi

# ---- 5. 可选额外配置 ----
if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -f "$GITHUB_WORKSPACE/Config-EXTRA.txt" ]; then
  echo "customize: appending Config-EXTRA.txt"
  cat "$GITHUB_WORKSPACE/Config-EXTRA.txt" >> .config
fi

# 不注入 root 密码 / PON SN / MAC / LOID / 校准数据：这些属于 factory 卷里的设备数据。
