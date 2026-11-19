#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PT1570-R10：PonWRT-TYFZA1 v0.8.5-beta WiFi 信号修复护栏。

背景（2026-11-15 实机反馈：run34 刷入后「WiFi 信号还是不行」）：

  * 原厂 config.xml 里 WLAN_RFPOWER_SCALE=0 / WLAN_FAKE_TX_POWER=0 /
    POWER_OPTIMIZATION_ENABLE=0 / YH_WIFI_LIMIT_WEB_ENABLE=0，即原厂
    不在 by-rate 标定之外再套一层功率限制。
  * PonWRT 0.8.5 的 manifests/radio-stock-rf-dm.json 逆向原厂
    rtk_wifi6.ko：power_limit MIB 默认 0，capability selection 同时
    禁用可选的厂商 TXPWR_LMT / TXPWR_LMT_RU 限制表。
  * 我们沿用的旧版 rtl_ax_ap/power-tables.c 却把 SCC MAC0 的 0xd208
    bit20/21 与 0xd21c bit18 置 1，额外启用厂商限制表，把 TX 功率压到
    单板 by-rate 目标以下 —— 这是「信号/覆盖明显弱于原厂」的总闸。
  * 0.8.5 把这些位清零；by-rate 值本身已含 Linux 信道/用户/regdb 上限，
    因此清零不放宽合规，只是不再重复限功率。

本护栏确保：驱动修复在位、单 PE1 引擎没被 0.8.5 双 PE 架构整套替换、
0.8.5 实机射频表作为可切换 profile 完整留存、country/regdb 未被改动、
ucode 发射功率修复脚本在位。
"""
import hashlib
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
FW = ROOT / "files/lib/firmware/realtek/tyfza1"
DRV = ROOT / "board/wifi/rtl_ax_ap"
CU_DRV = ROOT / "cu-h10/fw/board/wifi/rtl_ax_ap"
RFE = FW / "rtl8852ce/RFE54"
P085 = FW / "rtl8852ce/RFE54_PONWRT085"
DEFAULT = RFE / "RTK66587_BPF"
YH1570 = RFE / "RTK66587_BPF_YH1570"
WIRE = ROOT / "files/etc/config/wireless"

# 0.8.5-beta sysupgrade.bin 内 rootfs.squashfs 解出的关键表 sha256
P085_SHA = {
    "PHY_REG.txt": "b0c44852223bc5d9bb118140d7dbbb4ac42f110c491d49f0e607826eeeb73a19",
    "PHY_REG_GAIN.txt": "b36e6fc7fa2acd50f0d0f407f6e29f459361f399a57553ca60ae6652233ded3a",
    "RadioA.txt": "d5fd415ad81d086e5833968cf03126f52226b571020e1bfaecd505e62a55072c",
    "RadioB.txt": "b2dd5527add93a98fa21c78f05d5b0b9e9ee72d90267e7da24336f006a29f8af",
    "TXPWR_ByRate.txt": "a59f31291289c6104cd3c528a259bfdd3ccb4036fc13e68703e1a29f9bfae479",
    "TXPWR_LMT.txt": "9ffdba5396c4ede69cdf3f839823fc4fecc47e6ead9d42451b2462b49730310c",
    "RTK66587_BPF/PHY_REG.txt": "db15ba2ffaa450f2451475cc800b707aa0d4aa9921913f10acae12dc52b94913",
    "RTK66587_BPF/PHY_REG_GAIN.txt": "0d1735af7c8b16250a8287d00593b8cec1887b39de3590caa593739df7be2a8d",
    "RTK66587_BPF/TXPWR_ByRate.txt": "5d4e47ddaab7ea0c5e611133ccd9aef17c16146f41c9999bef6068acf9fe53f7",
    "RTK66587_BPF/TXPWR_LMT.txt": "65627ea0c4c6b83950345ba921ceee8ce72bd5ff36f842f33eb6d332ac7041a0",
}
# 原厂 PT1570 专用表（run34 已整合，本轮保持不动）
YH1570_SHA = {
    "PHY_REG.txt": "f3f595efcc0062889257bd8ce330ae6a5085d5e883220ee6cd0a5f7e7209a39e",
    "PHY_REG_GAIN.txt": "ae9e1f895fdfc7674c5717bef1a15183530d15f83d115fa9b501804ec34599da",
    "TXPWR_ByRate.txt": "dba95b9fb0d7a7dbeda69e4aee377ef13834593c33c67179d8338f18ad9b7dab",
}

PE_ENGINE = os.environ.get("WIFI_PE_ENGINE", "single")
count = 0


def ok(cond, msg):
    global count
    print(("  PASS  " if cond else "  FAIL  ") + msg)
    if not cond:
        sys.exit(1)
    count += 1


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def txt(p):
    return p.read_text("utf-8", "replace")


print("=== PonWRT-TYFZA1 v0.8.5 WiFi 信号修复护栏 ===")

# ---- 1. 驱动层：功率限制位修复 ----
pt = DRV / "power-tables.c"
ok(pt.is_file(), "R10 power-tables.c 存在")
s = txt(pt)
ok("TYFZA1's original power_limit MIB defaults to 0" in s,
   "power-tables.c 带 0.8.5 原厂功率限制说明")
ok("rtl_ax_update32(io, 0xd208, 0x00300000, 0);" in s,
   "0xd208 SCC MAC0 厂商限制位已清零")
ok("rtl_ax_update32(io, 0xd21c, 0x00040000, 0);" in s,
   "0xd21c 厂商限制位已清零")
ok("0x00300000, 0x00300000" not in s, "旧的 0xd208 置位逻辑已移除")
ok("!(io->read32(io->ctx, 0xd21c) & 0x00040000)" not in s,
   "旧的 0xd21c 置位读回校验已移除")
ok((CU_DRV / "power-tables.c").is_file()
   and sha(CU_DRV / "power-tables.c") == sha(pt),
   "CU H10 驱动副本同步了同一修复")

# ---- 2. PE 架构护栏 ----
# 默认 single： insist on the proven single-PE1 reference build.
# dual (experimental branch): skip these; verify-dual-pe-port.py covers it.
if PE_ENGINE == "dual":
    print("  SKIP  单 PE1 架构断言（WIFI_PE_ENGINE=dual，改由 verify-dual-pe-port.py 把关）")
else:
    ok(not (DRV / "pe-core.c").exists(), "未引入 0.8.5 的 pe-core.c（会破坏单 PE1 引擎）")
    ok(len(list(DRV.glob("*"))) < 73, "驱动仍是 60 文件参考版，不是 0.8.5 的 73 文件版")
    pe = DRV / "pe-tx-code.h"
    ok(pe.is_file()
       and hashlib.md5(pe.read_bytes()).hexdigest() == "7eb49893f43b897bf03fa82ae2323984",
       "pe-tx-code.h 仍是已验证的单 PE1 版（4076 words）")
    ok(len([x for x in txt(pe).splitlines() if "0x" in x]) == 4076,
       "PE 程序指令数 4076（0.8.5 是 6904，不能混用）")
    ov = txt(ROOT / "scripts/overlay-wifi-driver.sh")
    ok("EXP_PE_MD5=7eb49893f43b897bf03fa82ae2323984" in ov,
       "overlay-wifi-driver.sh 仍强校验单 PE1 引擎")

# ---- 3. 0.8.5 完整射频表作为可切换 profile ----
ok(P085.is_dir(), "RFE54_PONWRT085 profile 目录存在")
files085 = sorted(str(x.relative_to(P085)) for x in P085.rglob("*.txt"))
ok(len(files085) == 26, "0.8.5 profile 26 个参数表齐全（顶层 14 + FEM 12）")
for name, want in P085_SHA.items():
    p = P085 / name
    ok(p.is_file() and sha(p) == want, "0.8.5 表 %s 与 sysupgrade.bin 解出的一致" % name)
ok(len([x for x in (P085 / "RTK66587_BPF").glob("*.txt")]) == 12,
   "0.8.5 默认 FEM 目录 12 表齐全")
ok("version = 51" in txt(P085 / "RTK66587_BPF/PHY_REG_GAIN.txt"),
   "0.8.5 FEM 是通用 v51 标定")
ok("17 17 18 19" in txt(P085 / "RTK66587_BPF/TXPWR_ByRate.txt"),
   "0.8.5 by-rate 高阶 MCS 功率高于旧版（14/15/17/19 -> 17/17/18/19）")
ok(sha(P085 / "RTK66587_BPF/TXPWR_LMT.txt") == sha(DEFAULT / "TXPWR_LMT.txt"),
   "TXPWR_LMT 功率上限表与原版一致（未放宽 regdb）")

# ---- 4. 原厂资产 / 合规边界保持 ----
for name, want in YH1570_SHA.items():
    ok((DEFAULT / name).is_file() and sha(DEFAULT / name) == want,
       "默认表仍是原厂 YH1570 " + name)
    ok((YH1570 / name).is_file() and sha(YH1570 / name) == want,
       "YH1570 溯源目录未被改动 " + name)
wire = txt(WIRE)
ok(wire.count("option disabled '0'") == 2, "两个 radio 仍默认启用")
ok("option country 'CN'" in wire and "country_code=US" not in wire,
   "regdomain 保持 CN（不跟随原厂 US，不擅自改功率上限）")

# ---- 5. 0.8.5 ucode 发射功率修复脚本 ----
fix = ROOT / "scripts/apply-ponwrt-txpower-fixes.sh"
ok(fix.is_file(), "apply-ponwrt-txpower-fixes.sh 存在")
fs = txt(fix)
for tag in ("txpower-null", "txpower-fail", "setup-return", "setup-check"):
    ok("'" + tag + "'" in fs, "ucode 修复含锚点 " + tag)
ok("PONWRT_TXPOWER_FIX=SKIP" in fs, "找不到 wifi-scripts 时只告警、不阻断编译")

print("  PONWRT085_WIFI_OK=True checks=%d" % count)
