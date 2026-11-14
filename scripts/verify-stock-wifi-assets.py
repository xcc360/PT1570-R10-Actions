#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PT1570-R10 原厂 WiFi 整合资产护栏。

2026-11-14 从 D:\\ONT\\PT1570-R10\\BackUp-原厂\\mtd8-ubi_r0.bin 解包对比：
原厂 rtk_wifi6.ko 里只出现一个 FEM 名 RTK66587_BPF_YH1570，
/etc/conf/rtl8852ce/RFE54/RTK66587_BPF_YH1570/PHY_REG_GAIN.txt 头注释是
"//8832CR RFE54 version = 52-for 17C"，而上游 PonWRT 带的是通用
RTK66587_BPF（version = 51）。现用开源 rtl_ax_ap 驱动在
phy.c / limits.c / power-tables.c 里硬编码读 RTK66587_BPF，
所以把该目录的 3 个差异表替换成原厂 PT1570 专用版即可无改驱动生效。
"""
import hashlib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
FW = ROOT / "files/lib/firmware/realtek/tyfza1"
DEFAULT = FW / "rtl8852ce/RFE54/RTK66587_BPF"
YH1570 = FW / "rtl8852ce/RFE54/RTK66587_BPF_YH1570"
GENERIC = FW / "rtl8852ce/RFE54/RTK66587_BPF_GENERIC"
RTC7646 = FW / "rtl8192xbe/RFE54/RTC7646"

# 原厂 PT1570 专用表（YH1570）3 个差异文件的 sha256
EXPECT = {
    "PHY_REG.txt": "f3f595efcc0062889257bd8ce330ae6a5085d5e883220ee6cd0a5f7e7209a39e",
    "PHY_REG_GAIN.txt": "ae9e1f895fdfc7674c5717bef1a15183530d15f83d115fa9b501804ec34599da",
    "TXPWR_ByRate.txt": "dba95b9fb0d7a7dbeda69e4aee377ef13834593c33c67179d8338f18ad9b7dab",
}
NAMES5 = [
    "PHY_REG.txt", "PHY_REG_GAIN.txt", "RadioA.txt", "RadioB.txt",
    "TXPWR_ByRate.txt", "TXPWR_LMT.txt", "TXPWR_LMT_6G_LOW.txt",
    "TXPWR_LMT_6G_STD.txt", "TXPWR_LMT_RU.txt",
    "TXPWR_LMT_RU_6G_LOW.txt", "TXPWR_LMT_RU_6G_STD.txt",
    "TXPWR_TrackTSSI.txt",
]
NAMES2 = [
    "PHY_REG.txt", "PHY_REG_GAIN.txt", "RadioA.txt", "RadioB.txt",
    "TXPWR_ByRate.txt", "TXPWR_LMT.txt", "TXPWR_LMT_RU.txt",
    "TXPWR_TrackTSSI.txt",
]

ok_count = 0


def ok(cond, msg):
    global ok_count
    print(("  PASS  " if cond else "  FAIL  ") + msg)
    if not cond:
        sys.exit(1)
    ok_count += 1


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


print("=== PT1570-R10 原厂 WiFi 整合资产 ===")

for name, want in EXPECT.items():
    p = DEFAULT / name
    ok(p.is_file(), "默认 FEM 表存在 " + name)
    ok(sha(p) == want, "默认 %s == 原厂 YH1570 sha256" % name)
    ok((YH1570 / name).is_file() and sha(YH1570 / name) == sha(p),
       "YH1570 溯源目录与默认一致 " + name)
    ok((GENERIC / name).is_file() and sha(GENERIC / name) != sha(p),
       "通用版独立留存且不同 " + name)

gain = (DEFAULT / "PHY_REG_GAIN.txt").read_text("utf-8", "replace")
ok("version = 52-for 17C" in gain,
   "默认 PHY_REG_GAIN 是 RTL9617C 平台 v52 标定（不是通用 v51）")
gen_gain = (GENERIC / "PHY_REG_GAIN.txt").read_text("utf-8", "replace")
ok("version = 51" in gen_gain, "通用备份仍是 v51，可回滚")

ok(all((YH1570 / n).is_file() for n in NAMES5),
   "YH1570 溯源目录 12 文件齐全")
ok(all((GENERIC / n).is_file() for n in NAMES5),
   "GENERIC 回滚目录 12 文件齐全")
ok(all((RTC7646 / n).is_file() for n in NAMES2),
   "2.4G 备选 FEM RTC7646 8 文件齐全")
ok((FW / "rtl8192xbe/RFE54/RTK66287/PHY_REG_GAIN.txt").is_file(),
   "2.4G 默认表 RTK66287 保持原样（未改）")

wire = (ROOT / "files/etc/config/wireless").read_text("utf-8", "replace")
ok(wire.count("option disabled '0'") == 2, "两个 radio 仍默认启用")
ok(wire.count("option he_su_beamformer '1'") == 2,
   "两个 radio 都带原厂 HE beamforming 配置")
ok("option country 'CN'" in wire and "country_code=US" not in wire,
   "regdomain 保持 CN（不跟随原厂 US）")

tune = ROOT / "files/etc/uci-defaults/96-pt1570-wifi-tuning"
ok(tune.is_file(), "96-pt1570-wifi-tuning 存在")
ok('board_name)" = "youhua,pt1570-r10"' in tune.read_text("utf-8", "replace"),
   "tuning 脚本只对 R10 生效")

print("  STOCK_WIFI_OK=True checks=%d" % ok_count)
