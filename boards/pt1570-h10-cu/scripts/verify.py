#!/usr/bin/env python3
"""Static verification for the PT1570-H10-CU rtw89 experimental firmware build.

Updated 2026-11-26 for run28: upstream refactor HEAD 79b6a451b68f, where
rtw89 moved from kernel built-in symbols to mac80211 backports modules and
dedicated AP firmware packages. The old 741/742 kernel patches are obsolete.
"""
import os
import pathlib
import sys

SRC = pathlib.Path(os.environ.get("SRC_DIR", "."))
ASSETS = pathlib.Path(os.environ.get(
    "ASSET_DIR", os.environ.get("GITHUB_WORKSPACE", ".")))

errors = []


def check(cond, msg):
    if cond:
        print("  OK   " + msg)
    else:
        errors.append(msg)
        print("  FAIL " + msg, file=sys.stderr)


def read(path):
    try:
        return pathlib.Path(path).read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""


cfg = read(SRC / "target/linux/rtl9617c/config-6.18")
dotconfig = read(SRC / ".config")
dtsi = read(SRC / "target/linux/rtl9617c/dts/rtk-taurus.dtsi")
dts = read(ASSETS / "board/dts/rtl9617c-pt1570-h10-cu-rtw89.dts")
mk = read(SRC / "target/linux/rtl9617c/image/Makefile")
plat = read(SRC / "target/linux/rtl9617c/base-files/lib/upgrade/platform.sh")
board_d = read(SRC / "target/linux/rtl9617c/base-files/etc/board.d/02_network")
wireless = read(ASSETS / "files/etc/config/wireless")
realtek_mk = read(SRC / "package/kernel/mac80211/realtek.mk")
fw_dir = SRC / "target/linux/rtl9617c/embedded-firmware/rtw89"

print("=== verify-h10-cu-rtw89-exp.py (2026-11-26 run28 baseline) ===")

# 1) New upstream rtw89 layout: AP firmware package + mac80211 patches.
check((SRC / "package/firmware/rtw89-ap-firmware/Makefile").is_file(),
      "upstream rtw89-ap-firmware package present")
for name in [
    "100-wifi-rtw89-ap-firmware-variant.patch",
    "101-wifi-rtw89-factory-calibration.patch",
    "102-wifi-rtw89-8852c-ap-firmware-support.patch",
    "103-wifi-rtw89-add-8192xbe.patch",
]:
    check((SRC / "package/kernel/mac80211/patches/rtl" / name).is_file(),
          "mac80211 rtw89 patch present: " + name)
check("KernelPackage/rtw89-8192xbe" in realtek_mk,
      "realtek.mk has rtw89-8192xbe kernel package")
check("CONFIG_RTW89_8192XBE=y" not in cfg
      and "CONFIG_RTW89_8852CE=y" not in cfg,
      "old built-in CONFIG_RTW89_* removed from target config")

# 2) Thermal guard -- keep the measured -12C correction.
check("deviation = <0xffffd120>" in dts,
      "DTS thermal deviation 0xffffd120 (-12C)")
check("deviation = <0xfffcd120>" not in dts,
      "DTS has no fatal 0xfffcd120 value")

# 3) WiFi DT chain.
check("pcie0_port:" in dtsi and "pcie1_port:" in dtsi,
      "DTSI exposes pcie0_port/pcie1_port")
check("&pcie0_port" in dts and "wifi5g: wifi@0,0" in dts,
      "5G wifi node attached to &pcie0_port")
check("&pcie1_port" in dts and "wifi2g: wifi@0,0" in dts,
      "2.4G wifi node attached to &pcie1_port")
check("pci10ec,c852" in dts, "DTS 5G node pci10ec,c852")
check("pci10ec,0192" in dts, "DTS 2.4G node pci10ec,0192")
check("realtek,ap-firmware" in dts, "DTS requests AP firmware variant")
check(dts.count("realtek,rfe-type = <54>") >= 2,
      "DTS sets realtek,rfe-type = <54> on both radios")
check("irq-affinity = <1>" in dts and "irq-affinity = <2>" in dts,
      "DTS pins PCIe MSI affinity to CPU1/CPU2")
check(dts.count("wifi-calibration@") >= 2,
      "DTS has two wifi-calibration cells")
check("wifi-calibration@2000" in dts and "wifi-calibration@3000" in dts,
      "DTS calibration offsets 0x2000/0x3000")
check('volname = "factory"' in dts, "DTS factory UBI volume")
check(dts.count("nvmem-cells = <&wifi_cal_") >= 2,
      "DTS wifi nodes bind calibration nvmem cells")

# 4) Early firmware fallback + regulatory database.
check('CONFIG_EXTRA_FIRMWARE="rtw89/rtw8852c_fw.bin' in cfg,
      "rtw89 fallback firmware baked into kernel")
check("CONFIG_EXTRA_FIRMWARE=.*regulatory.db" in cfg
      or ("CONFIG_EXTRA_FIRMWARE=" in cfg and "regulatory.db" in cfg),
      "regulatory.db baked into kernel")
for name in ("rtw8852c_fw.bin", "rtw8192xb_fw.bin"):
    check((fw_dir / name).is_file() and (fw_dir / name).stat().st_size > 0,
          "fallback firmware blob present: " + name)
# run28: blobs must NOT be packaged into base-files, else apk aborts with
# "trying to overwrite ... owned by base-files" vs wireless-regdb /
# rtl8852ce-firmware (H10 run18 failure).
bf_fw = SRC / "target/linux/rtl9617c/base-files/lib/firmware"
for name in ("regulatory.db", "regulatory.db.p7s", "rtw89/rtw8852c_fw.bin"):
    check(not (bf_fw / name).exists(),
          "no base-files firmware conflict: " + name)

# 5) Profile, board whitelist and device packages.
check("youhua_pt1570_h10_cu_rtw89_exp" in mk, "image/Makefile device profile")
check("DEVICE_DTS := rtl9617c-pt1570-h10-cu-rtw89" in mk,
      "image/Makefile DTS ref")
check("kmod-rtw89-8852ce" in mk and "kmod-rtw89-8192xbe" in mk,
      "image/Makefile installs both rtw89 chip packages")
check("rtl8852ce-ap-firmware" in mk and "rtl8192xbe-ap-firmware" in mk,
      "image/Makefile installs both AP firmware packages")
check("youhua,pt1570-h10-cu-rtw89-exp" in plat,
      "platform.sh board whitelist")
check("youhua,pt1570-h10-cu-rtw89-exp" in board_d,
      "board.d/02_network registration")

# 6) H10-CU wireless overlay: avoid DFS auto and keep 5G on br-lan.
check("option channel '36'" in wireless and "option htmode 'HE80'" in wireless,
      "wireless overlay pins 5G to non-DFS channel 36 / HE80")
check("option channel '6'" in wireless and "option htmode 'HE40'" in wireless,
      "wireless overlay pins 2.4G to channel 6 / HE40")
check(wireless.count("option network 'lan'") >= 2,
      "both SSIDs are attached to br-lan")

# 7) .config assertions (only when .config is non-empty).
if dotconfig.strip():
    required = [
        "CONFIG_TARGET_rtl9617c_generic_DEVICE_youhua_pt1570_h10_cu_rtw89_exp=y",
        "CONFIG_PACKAGE_kmod-rtw89-pci=y",
        "CONFIG_PACKAGE_kmod-rtw89-8852ce=y",
        "CONFIG_PACKAGE_kmod-rtw89-8192xbe=y",
        "CONFIG_PACKAGE_rtl8852ce-ap-firmware=y",
        "CONFIG_PACKAGE_rtl8192xbe-ap-firmware=y",
        "CONFIG_DRIVER_11AC_SUPPORT=y",
        "CONFIG_DRIVER_11AX_SUPPORT=y",
        "CONFIG_PACKAGE_wpad-openssl=y",
        "CONFIG_PACKAGE_hostapd-common=y",
        "CONFIG_PACKAGE_wifi-scripts=y",
        "CONFIG_WIFI_SCRIPTS_UCODE=y",
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

# 8) APK repository signing keys.
for key in ("openwrt-snapshots.pem", "immortalwrt-25.12.pem"):
    kp = ASSETS / "files/etc/apk/keys" / key
    check(kp.is_file() and kp.stat().st_size > 100,
          "apk key asset present: " + key)
    ktext = read(kp)
    check("-----BEGIN PUBLIC KEY-----" in ktext
          and "-----END PUBLIC KEY-----" in ktext,
          "apk key asset is valid PEM: " + key)

if errors:
    print("\n%d assertion(s) FAILED:" % len(errors), file=sys.stderr)
    for e in errors:
        print("  - " + e, file=sys.stderr)
    sys.exit(1)
print("\nALL ASSERTIONS PASSED")
