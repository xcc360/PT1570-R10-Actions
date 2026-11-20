#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""WiFi 单一真源护栏（编译期，只读）。

R10 / H10-CU / H10-CU-refactor 三条构建通道共用 board/wifi/rtl_ax_ap。
仓库里不允许再出现第二份驱动副本，避免“改一份忘一份”导致某板静默丢失修复。
同时保留两板 hostapd 稳定性参数与 overlay 逻辑一致性检查。

用法:
  python3 scripts/verify-wifi-parity.py <REPO_ROOT>
  REPO_ROOT 默认取脚本所在仓库根（脚本位于 <root>/scripts/）。
"""
import sys, pathlib, hashlib

ROOT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1]
DRV = ROOT / "board/wifi/rtl_ax_ap"
DUP = ROOT / "cu-h10/fw/board/wifi/rtl_ax_ap"
R10_OVL = ROOT / "scripts/overlay-wifi-driver.sh"
CU_OVL = ROOT / "cu-h10/fw/scripts/overlay-wifi-driver.sh"
RF_OVL = ROOT / "scripts/refactor/overlay-wifi-pcie.sh"
EXP_PE_MD5 = "7eb49893f43b897bf03fa82ae2323984"

count = 0


def ok(cond, msg):
    global count
    print(("  OK   " if cond else "  FAIL ") + msg)
    if not cond:
        sys.exit(1)
    count += 1


def md5(p):
    return hashlib.md5(p.read_bytes()).hexdigest() if p.is_file() else "(缺失)"


def ovl_logic(p):
    return [line.rstrip() for line in p.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.strip().startswith("#")]


print("=== WiFi 单一真源护栏 ===")

# 1~3. 唯一驱动源存在、足量、无第二副本
ok(DRV.is_dir(), f"驱动单一真源存在: {DRV}")
files = sorted(p.name for p in DRV.iterdir() if p.is_file()) if DRV.is_dir() else []
ok(len(files) >= 60, f"驱动文件数 {len(files)} >= 60")
ok(not DUP.exists(), f"不存在重复驱动副本: {DUP}")

# 4. 单 PE1 参考版锚点
ok(md5(DRV / "pe-tx-code.h") == EXP_PE_MD5, "pe-tx-code.h 为已验证单 PE1 参考版")

# 5~7. 三条通道的 overlay 都从真源取，且两板注入逻辑一致
for p, label in ((R10_OVL, "R10"), (CU_OVL, "CU"), (RF_OVL, "refactor")):
    txt = p.read_text(encoding="utf-8") if p.is_file() else ""
    ok(p.is_file() and '$ASSETS/board/wifi/rtl_ax_ap' in txt,
       f"{label} overlay 指向驱动单一真源")
ok(ovl_logic(R10_OVL) == ovl_logic(CU_OVL),
   "R10 / CU overlay 注入逻辑一致")

# 8~11. 两板稳定性配置仍在（单一驱动源不代表配置也能合并）
STAB = [
    (ROOT / "files/etc/uci-defaults/96-pt1570-wifi-tuning", "R10"),
    (ROOT / "cu-h10/fw/files-cu/etc/uci-defaults/99-pt1570-h10-cu-wifi-stability", "CU"),
]
for p, label in STAB:
    ok(p.is_file(), f"{label} 稳定性 uci-defaults 存在: {p.name}")
    txt = p.read_text(encoding="utf-8") if p.is_file() else ""
    ok("skip_inactivity_poll" in txt and "disassoc_low_ack" in txt,
       f"{label} 含 skip_inactivity_poll + disassoc_low_ack")

print(f"WIFI_PARITY_OK=True ({count} 项断言通过)")
