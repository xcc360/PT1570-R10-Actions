#!/usr/bin/env python3
"""Static assertions for the PT1570-R10 rtw89 experimental firmware build.

Run from the workflow after Clone/Apply/Configure. Exits 1 on any failure.
Updated 2026-11-25 for upstream d39cfc6367e3 (rtw89 AP-firmware split) and
for the thermal/port/MAC regressions that bricked the 2026-11-22 firmware.
"""
import os
import sys

SRC = os.environ.get("SRC_DIR", ".")
ASSETS = os.environ.get("ASSET_DIR",
                        os.environ.get("GITHUB_WORKSPACE", "."))

errors = []


def check(cond, msg):
    if cond:
        print("  OK   " + msg)
    else:
        errors.append(msg)
        print("  FAIL " + msg, file=sys.stderr)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            return f.read()
    except Exception:
        return ""


cfg = read(os.path.join(SRC, "target/linux/rtl9617c/config-6.18"))
dtsi = read(os.path.join(SRC, "target/linux/rtl9617c/dts/rtk-taurus.dtsi"))
dts = read(os.path.join(SRC, "target/linux/rtl9617c/dts/rtl9617c-pt1570-r10-rtw89.dts"))
mk = read(os.path.join(SRC, "target/linux/rtl9617c/image/Makefile"))
plat = read(os.path.join(SRC, "target/linux/rtl9617c/base-files/lib/upgrade/platform.sh"))
dotconfig = read(os.path.join(SRC, ".config"))
feeds = read(os.path.join(SRC, "feeds.conf.default"))
realtek_mk = read(os.path.join(SRC, "package/kernel/mac80211/realtek.mk"))

print("=== verify-r10-rtw89-exp.py (2026-11-25 baseline) ===")

# 1) New upstream rtw89 layout: AP firmware package + mac80211 patches.
check(os.path.isfile(os.path.join(SRC, "package/firmware/rtw89-ap-firmware/Makefile")),
      "upstream rtw89-ap-firmware package present")
for n, name in enumerate([
    "100-wifi-rtw89-ap-firmware-variant.patch",
    "101-wifi-rtw89-factory-calibration.patch",
    "102-wifi-rtw89-8852c-ap-firmware-support.patch",
    "103-wifi-rtw89-add-8192xbe.patch",
], start=1):
    check(os.path.isfile(os.path.join(
        SRC, "package/kernel/mac80211/patches/rtl", name)),
        "mac80211 rtw89 patch %d present" % n)
check("KernelPackage/rtw89-8192xbe" in realtek_mk,
      "realtek.mk has rtw89-8192xbe kernel package")
check("CONFIG_RTW89_8192XBE=y" not in cfg,
      "old built-in CONFIG_RTW89_8192XBE removed from target config")

# 2) Critical thermal guard -- this exact value bricked the device in run#3.
check("deviation = <0xffffd120>" in dts,
      "DTS thermal deviation 0xffffd120 (-12C, upstream 43c48a4c16)")
check("deviation = <0xfffcd120>" not in dts,
      "DTS has no fatal 0xfffcd120 (-208.6C critical-trip) value")

# 3) WiFi DT chain: PCIe port nodes, AP firmware, RFE type, factory calibration.
check("pcie0_port:" in dtsi and "pcie1_port:" in dtsi,
      "DTSI exposes pcie0_port/pcie1_port (baseline >= 2df200550b73)")
check("&pcie0_port" in dts and "wifi5g: wifi@0,0" in dts,
      "5G wifi node attached to &pcie0_port")
check("&pcie1_port" in dts and "wifi2g: wifi@0,0" in dts,
      "2.4G wifi node attached to &pcie1_port")
check("pci10ec,c852" in dts, "DTS 5G node pci10ec,c852")
check("pci10ec,0192" in dts, "DTS 2.4G node pci10ec,0192")
check("realtek,ap-firmware" in dts, "DTS requests AP firmware variant")
check(dts.count("realtek,rfe-type = <54>") >= 2,
      "DTS sets realtek,rfe-type = <54> on both radios")
check(dts.count("wifi-calibration@") >= 2,
      "DTS has two wifi-calibration cells")
check("wifi-calibration@2000" in dts and "wifi-calibration@3000" in dts,
      "DTS calibration offsets 0x2000/0x3000 (R10 TYFC0003)")
check('volname = "factory"' in dts, "DTS factory UBI volume")
check(dts.count("nvmem-cells = <&wifi_cal_") >= 2,
      "DTS wifi nodes bind calibration nvmem cells")

# 4) LAN ports: 0..3 + per-port MAC binding (upstream e23dc7d6fb/8eb4e46287).
for i in range(4):
    check(("port@%d {" % i) in dts, "DTS port@%d present" % i)
for i in range(1, 5):
    check(("nvmem-cells = <&base_mac %d>" % i) in dts,
          "DTS LAN port binds base_mac %d" % i)

# 5) Profile + board whitelist.
check("youhua_pt1570_r10_rtw89_exp" in mk, "image/Makefile device profile")
check("DEVICE_DTS := rtl9617c-pt1570-r10-rtw89" in mk, "image/Makefile DTS ref")
check("kmod-rtw89-8852ce" in mk and "kmod-rtw89-8192xbe" in mk,
      "image/Makefile installs both rtw89 chip packages")
check("rtl8852ce-ap-firmware" in mk, "image/Makefile installs AP firmware")
check("youhua,pt1570-r10-rtw89-exp" in plat, "platform.sh board whitelist")

# 6) External feed URL typo in upstream feeds.conf.default must be corrected.
check("crysister/rtl9617c-packages.git" in feeds,
      "feed URL corrected to crysister/rtl9617c-packages.git")
check("cryster/rtl9617c-packages.git" not in feeds,
      "upstream typo cryster/... not present")

# 7) .config user-space + ccache settings (only when .config is non-empty).
if dotconfig.strip():
    required = [
        "CONFIG_TARGET_rtl9617c_generic_DEVICE_youhua_pt1570_r10_rtw89_exp=y",
        "CONFIG_PACKAGE_kmod-rtw89-pci=y",
        "CONFIG_PACKAGE_kmod-rtw89-8852ce=y",
        "CONFIG_PACKAGE_kmod-rtw89-8192xbe=y",
        "CONFIG_PACKAGE_rtl8852ce-ap-firmware=y",
        "CONFIG_PACKAGE_rtl8192xbe-ap-firmware=y",
        "CONFIG_PACKAGE_wpad-openssl=y",
        "CONFIG_PACKAGE_hostapd-common=y",
        "CONFIG_PACKAGE_iw=y",
        "CONFIG_PACKAGE_fitblk=y",
        "CONFIG_PACKAGE_rtl9617c-pon-control=y",
        "CONFIG_PACKAGE_luci-app-rtl9617c-pon=y",
        "CONFIG_DEVEL=y",
        "CONFIG_CCACHE=y",
        'CONFIG_CCACHE_DIR="/mnt/build_wrt/.ccache"',
    ]
    for sym in required:
        check(sym in dotconfig, ".config " + sym)
    check("CONFIG_PACKAGE_kmod-rtl-ax-ap=y" not in dotconfig
          and "rtl_ax_ap" not in dotconfig,
          "no private rtl_ax_ap in .config")

# 8) No private driver assets injected into source.
priv = os.path.join(SRC, "board/wifi/rtl_ax_ap")
check(not os.path.exists(priv), "no private rtl_ax_ap source in tree")

# 9) APK repository signing keys (both OpenWrt snapshot and ImmortalWrt).
assets_keys = os.path.join(ASSETS, "files/etc/apk/keys")
for key in ("openwrt-snapshots.pem", "immortalwrt-25.12.pem"):
    kp = os.path.join(assets_keys, key)
    check(os.path.isfile(kp) and os.path.getsize(kp) > 100,
          "apk key asset %s present" % key)
    ktext = read(kp)
    check("-----BEGIN PUBLIC KEY-----" in ktext and "-----END PUBLIC KEY-----" in ktext,
          "apk key asset %s is valid PEM" % key)

if errors:
    print("\n%d assertion(s) FAILED:" % len(errors), file=sys.stderr)
    for e in errors:
        print("  - " + e, file=sys.stderr)
    sys.exit(1)
print("\nALL ASSERTIONS PASSED")
