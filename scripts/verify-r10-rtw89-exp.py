#!/usr/bin/env python3
"""Static assertions for the experimental PT1570-R10 rtw89 firmware build.
Run from workflow after Configure + board injection. Exits 1 on any failure.
"""
import os
import sys

SRC = os.environ.get("SRC_DIR", ".")
ASSETS = os.environ.get("GITHUB_WORKSPACE", ".")

errors = []
def check(cond, msg):
    if cond:
        print("  OK   " + msg)
    else:
        errors.append(msg)
        print("  FAIL " + msg, file=sys.stderr)

def read(p):
    try:
        with open(p, encoding="utf-8", errors="ignore") as f:
            return f.read()
    except Exception:
        return ""

cfg = read(os.path.join(SRC, "target/linux/rtl9617c/config-6.18"))
dts = read(os.path.join(SRC, "target/linux/rtl9617c/dts/rtl9617c-pt1570-r10-rtw89.dts"))
mk = read(os.path.join(SRC, "target/linux/rtl9617c/image/Makefile"))
plat = read(os.path.join(SRC, "target/linux/rtl9617c/base-files/lib/upgrade/platform.sh"))
dotconfig = read(os.path.join(SRC, ".config"))

print("=== verify-r10-rtw89-exp.py ===")

# 1) kernel rtw89 built-in
for sym in ["CONFIG_RTW89=y", "CONFIG_RTW89_CORE=y", "CONFIG_RTW89_PCI=y",
            "CONFIG_RTW89_8192XBE=y", "CONFIG_RTW89_8852CE=y",
            "CONFIG_MAC80211=y", "CONFIG_CFG80211=y"]:
    check(sym in cfg, "kernel " + sym)

# 2) firmware present in source tree
fw2g = os.path.join(SRC, "target/linux/rtl9617c/base-files/lib/firmware/rtw89/rtw8192xb_fw.bin")
fw5g = os.path.join(SRC, "target/linux/rtl9617c/base-files/lib/firmware/rtw89/rtw8852c_fw.bin")
check(os.path.exists(fw2g) and os.path.getsize(fw2g) > 200000, "rtw8192xb_fw.bin exists (~245K)")
check(os.path.exists(fw5g) and os.path.getsize(fw5g) > 280000, "rtw8852c_fw.bin exists (~315K)")

# 3) DTS wifi nodes + calibration cells (the critical calibration chain)
check("pci10ec,c852" in dts, "DTS 5G node pci10ec,c852")
check("pci10ec,0192" in dts, "DTS 2.4G node pci10ec,0192")
check(dts.count("wifi-calibration@") >= 2, "DTS two wifi-calibration cells")
check("wifi-calibration@2000" in dts and "wifi-calibration@3000" in dts,
      "DTS calibration offsets 0x2000/0x3000 (match R10 TYFC0003)")
check('volname = "factory"' in dts, "DTS factory UBI volume")
check("wifi-calibration" in dts and dts.count("nvmem-cells = <&wifi_cal_") >= 2,
      "DTS wifi nodes bind calibration nvmem cells")

# 4) profile + board whitelist
check("youhua_pt1570_r10_rtw89_exp" in mk, "image/Makefile device profile")
check("DEVICE_DTS := rtl9617c-pt1570-r10-rtw89" in mk, "image/Makefile DTS ref")
check("youhua,pt1570-r10-rtw89-exp" in plat, "platform.sh board whitelist")

# 5) .config user-space packages (only when .config exists and non-empty)
if dotconfig.strip():
    for p in ["wpad-openssl", "hostapd-common", "iw", "fitblk"]:
        check("CONFIG_PACKAGE_" + p + "=y" in dotconfig, "CONFIG_PACKAGE_" + p + "=y")
    # private driver must NOT be present
    check("CONFIG_PACKAGE_kmod-rtl-ax-ap" not in dotconfig and "rtl_ax_ap" not in dotconfig,
          "no private rtl_ax_ap in .config")

# 6) no private driver assets injected into source
priv = os.path.join(SRC, "board/wifi/rtl_ax_ap")
check(not os.path.exists(priv), "no private rtl_ax_ap source in tree")

if errors:
    print("\n%d assertion(s) FAILED:" % len(errors), file=sys.stderr)
    for e in errors:
        print("  - " + e, file=sys.stderr)
    sys.exit(1)
print("\nALL ASSERTIONS PASSED")
