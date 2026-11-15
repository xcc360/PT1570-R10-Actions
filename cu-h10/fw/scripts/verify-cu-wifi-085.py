#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PT1570-H10-CU：PonWRT-TYFZA1 v0.8.5 WiFi 整合护栏（本地 / CI 共用）。

与 R10 的 scripts/verify-ponwrt085-wifi.py 同源，但按 CU 的独立资产路径
（cu-h10/fw/）校验：

  * CU 驱动副本的 power-tables.c 必须带 0.8.5 的功率限制位修复
    （0xd208 bit20/21、0xd21c bit18 清零；否则厂商 TXPWR_LMT 表会把 TX
    压到 by-rate 目标以下，表现为「信号远弱于原厂」）；
  * 仍用已实机验证的单 PE1 引擎（60 文件 / 4076 words），绝不能整套换成
    0.8.5 的 73 文件双 PE 架构；
  * 0.8.5 实机 26 张 v51 射频表作为可切换 profile 完整留存，且与 R10
    资产逐字节一致；
  * 默认无线配置两个 radio 都启用、regdomain CN、SSID 为 CU 机型串；
  * 开机 WiFi 诊断脚本在位（run3 刷入仍无无线，需要一次实机证据）。
"""
import hashlib
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]          # 仓库根
CU = ROOT / 'cu-h10/fw'
R10 = ROOT
CU_DRV = CU / 'board/wifi/rtl_ax_ap'
CU_FW = CU / 'files-cu/lib/firmware/realtek/tyfza1'
CU_RFE = CU_FW / 'rtl8852ce/RFE54'
CU_P085 = CU_FW / 'rtl8852ce/RFE54_PONWRT085'
R10_P085 = R10 / 'files/lib/firmware/realtek/tyfza1/rtl8852ce/RFE54_PONWRT085'
WIRE = CU / 'files-cu/etc/config/wireless'
DIAG = CU / 'files-cu/etc/uci-defaults/97-pt1570-h10-cu-wifi-diag'
FIX = ROOT / 'scripts/apply-ponwrt-txpower-fixes.sh'

count = 0


def ok(cond, msg):
    global count
    print(('  OK   ' if cond else '  FAIL ') + msg)
    if not cond:
        sys.exit(1)
    count += 1


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def txt(p):
    return p.read_text('utf-8', 'replace')


print('=== CU / PonWRT-TYFZA1 v0.8.5 WiFi 整合护栏 ===')

# ---- 1. 驱动层：功率限制位修复与 R10 同步 ----
pt = CU_DRV / 'power-tables.c'
ok(pt.is_file(), 'CU power-tables.c 存在')
s = txt(pt)
ok("TYFZA1's original power_limit MIB defaults to 0" in s,
   'CU power-tables.c 带 0.8.5 原厂功率限制说明')
ok('rtl_ax_update32(io, 0xd208, 0x00300000, 0);' in s, 'CU 0xd208 厂商限制位已清零')
ok('rtl_ax_update32(io, 0xd21c, 0x00040000, 0);' in s, 'CU 0xd21c 厂商限制位已清零')
ok('0x00300000, 0x00300000' not in s, 'CU 旧的 0xd208 置位逻辑已移除')
ok((R10 / 'board/wifi/rtl_ax_ap/power-tables.c').is_file()
   and sha(R10 / 'board/wifi/rtl_ax_ap/power-tables.c') == sha(pt),
   'CU 与 R10 的 power-tables.c 逐字节一致（同批修复）')

# ---- 2. 不能整套换成 0.8.5 双 PE 架构 ----
ok(not (CU_DRV / 'pe-core.c').exists(), 'CU 未引入 0.8.5 的 pe-core.c（会破坏单 PE1 引擎）')
ok(len(list(CU_DRV.glob('*'))) < 73, 'CU 驱动仍是 60 文件参考版，不是 0.8.5 的 73 文件版')
pe = CU_DRV / 'pe-tx-code.h'
ok(pe.is_file()
   and hashlib.md5(pe.read_bytes()).hexdigest() == '7eb49893f43b897bf03fa82ae2323984',
   'CU pe-tx-code.h 仍是已验证的单 PE1 版（4076 words）')

# ---- 3. 0.8.5 射频表 profile ----
ok(CU_P085.is_dir(), 'CU RFE54_PONWRT085 profile 目录存在')
f085 = sorted(str(x.relative_to(CU_P085)) for x in CU_P085.rglob('*.txt'))
ok(len(f085) == 26, 'CU 0.8.5 profile 26 个参数表齐全（顶层 14 + FEM 12）')
r10 = sorted(str(x.relative_to(R10_P085)) for x in R10_P085.rglob('*.txt'))
ok(f085 == r10, 'CU 与 R10 的 0.8.5 表清单一致')
ok(all(sha(CU_P085 / f) == sha(R10_P085 / f) for f in f085),
   'CU 26 张表与 R10 / 0.8.5 实机资产逐字节一致')
ok('version = 51' in txt(CU_P085 / 'RTK66587_BPF/PHY_REG_GAIN.txt'),
   '0.8.5 FEM 是通用 v51 标定')
ok((CU_RFE / 'RTK66587_BPF_GENERIC').is_dir()
   and len(list((CU_RFE / 'RTK66587_BPF_GENERIC').glob('*.txt'))) == 12,
   'generic 回滚目录 12 表齐全')
ok((CU_RFE / 'RTK66587_BPF_YH1570').is_dir(), 'YH1570 溯源目录存在')
ok(sha(CU_P085 / 'RTK66587_BPF/TXPWR_LMT.txt')
   == sha(CU_RFE / 'RTK66587_BPF/TXPWR_LMT.txt'),
   'TXPWR_LMT 功率上限表与默认表一致（未放宽 regdb）')

# ---- 4. 默认无线配置 / 诊断脚本 ----
ok(WIRE.is_file(), 'CU /etc/config/wireless 存在')
w = txt(WIRE)
ok(w.count("option disabled '0'") == 2, '两个 radio 仍默认启用')
ok("option country 'CN'" in w and 'country_code=US' not in w,
   'regdomain 保持 CN（不擅自改功率上限）')
ok("PT1570-H10-CU" in w and 'PT1570-R10' not in w,
   'SSID 改为 CU 机型串（不再沿用 R10）')
ok(DIAG.is_file(), '开机 WiFi 诊断脚本 97-pt1570-h10-cu-wifi-diag 存在')
if DIAG.is_file():
    d = txt(DIAG)
    ok('youhua,pt1570-h10-cu' in d, '诊断脚本按 CU board_name 门控')
    ok('/sys/class/ieee80211' in d and 'rtl_ax_ap' in d,
       '诊断脚本收集 phy 注册与 rtl_ax_ap dmesg')
    try:
        r = subprocess.run(['sh', '-n', str(DIAG)], capture_output=True, text=True)
        ok(r.returncode == 0, 'sh -n 诊断脚本')
    except FileNotFoundError:
        print('  SKIP sh -n（本机无 sh）')

# ---- 5. 0.8.5 ucode 发射功率修复脚本 ----
ok(FIX.is_file(), 'apply-ponwrt-txpower-fixes.sh 存在（CU workflow 复用）')

print('CU_PONWRT085_WIFI_OK=True checks=%d' % count)
