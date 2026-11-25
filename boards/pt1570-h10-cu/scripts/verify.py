#!/usr/bin/env python3
"""Static verification for the PT1570-H10-CU rtw89 experimental board.

Extracted from the old inline workflow step so the unified workflow can call
one verify script per board. Baseline: 2df200550b73316094ff53c02899954beb22efeb.
"""
import hashlib
import os
import pathlib
import struct
import sys

SRC = pathlib.Path(os.environ.get("SRC_DIR", "."))
ASSETS = os.environ.get("ASSET_DIR", os.environ.get("GITHUB_WORKSPACE", "."))

errors = []


def check(cond, msg):
    if cond:
        print("  OK   " + msg)
    else:
        errors.append(msg)
        print("  FAIL " + msg, file=sys.stderr)


def read(path):
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""


cfg = read(SRC / "target/linux/rtl9617c/config-6.18")
dotconfig = read(SRC / ".config")
patch_dir = SRC / "target/linux/rtl9617c/patches-6.18"
fw_dir = SRC / "target/linux/rtl9617c/base-files/lib/firmware/rtw89"
board_d = (SRC / "target/linux/rtl9617c/base-files/etc/board.d/02_network")
dts_asset = os.path.join(ASSETS, "board/dts/rtl9617c-pt1570-h10-cu-rtw89.dts")

print("=== verify-h10-cu-rtw89-exp.py ===")

for sym in ["CONFIG_RTW89_8192XBE=y", "CONFIG_RTW89_8852CE=y"]:
    check(sym in cfg, "kernel " + sym)

expected = {"rtw8852c_fw.bin": 0x88520202, "rtw8192xb_fw.bin": 0x81920102}


def fw_suits(data):
    if data[0] == 0xFF:
        suits = []
        for i in range(data[1]):
            _cv, typ, mp, _rsvd, shift, size, _rsvd2 = struct.unpack_from(
                "<BBBBII4s", data, 16 + 16 * i)
            if typ == 1 and not mp:
                suits.append(data[shift:shift + size])
        if not suits:
            raise ValueError("no normal firmware suit")
        return suits
    return [data]


for name, want in expected.items():
    p = fw_dir / name
    if not p.is_file():
        check(False, "%s exists" % name)
        continue
    data = p.read_bytes()
    try:
        suits = fw_suits(data)
        ok = all(len(s) >= 4 and struct.unpack("<I", s[:4])[0] == want for s in suits)
    except Exception:
        ok = False
        suits = []
    check(ok, "%s chip/cut 0x%08x (%d bytes)" % (name, want, len(data)))
    if ok:
        print("    sha256=%s" % hashlib.sha256(data).hexdigest())

check((patch_dir / "741-8192xb-dlfw-preconfig.patch").is_file(),
      "8192XB DLFW preconfig patch injected")
check((patch_dir / "742-8192xb-thermal-direct-read.patch").is_file(),
      "8192XB thermal direct-read patch injected")

dts = read(pathlib.Path(dts_asset))
check("pci10ec,c852" in dts, "DTS 5G node pci10ec,c852")
check("pci10ec,0192" in dts, "DTS 2.4G node pci10ec,0192")

check('CONFIG_EXTRA_FIRMWARE="rtw89/rtw8852c_fw.bin' in cfg,
      "rtw89 firmware baked into kernel")
check("regulatory.db" in cfg and "CONFIG_EXTRA_FIRMWARE=" in cfg,
      "regulatory.db baked into kernel")
check("youhua,pt1570-h10-cu-rtw89-exp" in read(board_d),
      "board registered in board.d/02_network")

for sym in ["CONFIG_DRIVER_11AC_SUPPORT=y", "CONFIG_DRIVER_11AX_SUPPORT=y"]:
    check(sym in dotconfig, ".config " + sym)

if errors:
    print("\n%d assertion(s) FAILED:" % len(errors), file=sys.stderr)
    for e in errors:
        print("  - " + e, file=sys.stderr)
    sys.exit(1)
print("\nALL ASSERTIONS PASSED")
