#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PT1570-R10 / PT1570-H10-CU WiFi 资产一致性护栏（编译期，只读）。

目的：两板共用同一份已验证的单 PE1 参考驱动，但资产在仓库里存两份
(board/wifi/rtl_ax_ap/ 与 cu-h10/fw/board/wifi/rtl_ax_ap/)。本护栏强制
两处逐字节一致，防止"改一份忘一份"导致某板静默缺失修复——这是两板
WiFi 方案统一的核心保障。只校验、不修改任何文件，失败即 exit 1。

用法:
  python3 scripts/verify-wifi-parity.py <REPO_ROOT>
  REPO_ROOT 默认取脚本所在仓库根（脚本位于 <root>/scripts/）。
"""
import sys, pathlib, hashlib

ROOT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1]
R10_DRV = ROOT / "board/wifi/rtl_ax_ap"
CU_DRV = ROOT / "cu-h10/fw/board/wifi/rtl_ax_ap"
R10_OVL = ROOT / "scripts/overlay-wifi-driver.sh"
CU_OVL = ROOT / "cu-h10/fw/scripts/overlay-wifi-driver.sh"
EXP_PE_MD5 = "7eb49893f43b897bf03fa82ae2323984"

count = 0
def ok(cond, msg):
    global count
    print(("  OK   " if cond else "  FAIL ") + msg)
    if not cond:
        sys.exit(1)
    count += 1

def sha256(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def drv_files(d):
    return sorted(p.name for p in d.iterdir() if p.is_file())

print("=== WiFi 资产一致性护栏 (R10 <-> CU) ===")

# 1. 两处驱动目录都在、文件数量一致
ok(R10_DRV.is_dir(), f"R10 驱动目录存在: {R10_DRV}")
ok(CU_DRV.is_dir(), f"CU 驱动目录存在: {CU_DRV}")
r10f, cuf = drv_files(R10_DRV), drv_files(CU_DRV)
ok(len(r10f) >= 60, f"R10 驱动文件数 {len(r10f)} >= 60")
ok(r10f == cuf, f"两处驱动文件清单一致 ({len(r10f)} 文件)")

# 2. 逐文件 sha256 比对（决定性：任何一处被单独改动都会被抓出）
mismatch = [n for n in r10f
            if not (R10_DRV/n).is_file() or not (CU_DRV/n).is_file()
            or sha256(R10_DRV/n) != sha256(CU_DRV/n)]
ok(not mismatch, f"两处 60 文件逐字节一致" + (f" (差异: {mismatch[:8]})" if mismatch else ""))

# 3. 单 PE1 参考版 pe-tx-code.h（与两 workflow 既有护栏同锚点）
def md5(p):
    return hashlib.md5(p.read_bytes()).hexdigest() if p.is_file() else "(缺失)"
ok(md5(R10_DRV/"pe-tx-code.h") == EXP_PE_MD5,
   "R10 pe-tx-code.h 为已验证单 PE1 参考版")
ok(md5(CU_DRV/"pe-tx-code.h") == EXP_PE_MD5,
   "CU pe-tx-code.h 为已验证单 PE1 参考版")

# 4. overlay 脚本：忽略资产路径行/注释后，逻辑必须一致
def ovl_logic(p):
    lines = []
    for line in p.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith(("SRC=", "ASSETS=", "WRT=")):  # 允许两板各自资产路径
            continue
        lines.append(line.rstrip())
    return lines
ok(R10_OVL.is_file() and CU_OVL.is_file(), "两处 overlay 脚本存在")
ok(ovl_logic(R10_OVL) == ovl_logic(CU_OVL),
   "overlay 脚本逻辑一致（仅资产路径不同）")

# 5. 稳定性配置：两板各自的 uci-defaults 都带两项防断流设置
STAB = [
    (ROOT / "files/etc/uci-defaults/96-pt1570-wifi-tuning", "R10"),
    (ROOT / "cu-h10/fw/files-cu/etc/uci-defaults/99-pt1570-h10-cu-wifi-stability", "CU"),
]
for p, label in STAB:
    ok(p.is_file(), f"{label} 稳定性 uci-defaults 存在: {p.name}")
    txt = p.read_text(encoding="utf-8")
    ok("skip_inactivity_poll" in txt and "disassoc_low_ack" in txt,
       f"{label} 稳定性脚本含 skip_inactivity_poll + disassoc_low_ack")

print(f"WIFI_PARITY_OK=True ({count} 项断言通过)")
