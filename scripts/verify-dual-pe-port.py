#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PT1570-R10 双 PE 引擎移植护栏（feature/wifi-dual-pe-port-20261119）。

用途：确认 workflow 没有把双 PE 驱动悄悄换回已验证的单 PE1 参考版，
也确认我们加的 cached IRAM 别名修复真的落到了编译树和镜像里。

用法：
  verify-dual-pe-port.py check-tree <WRT>
  verify-dual-pe-port.py check-image <ROOTFS>
"""
import hashlib
import pathlib
import sys

count = 0
SKIP_SINGLE_PE = 'WIFI_PE_ENGINE'


def ok(cond, msg):
    global count
    print(("  PASS  " if cond else "  FAIL  ") + msg)
    if not cond:
        sys.exit(1)
    count += 1


def txt(p):
    return p.read_text('utf-8', 'replace')


mode = sys.argv[1] if len(sys.argv) > 1 else ''
root = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else None
if mode not in ('check-tree', 'check-image') or root is None:
    sys.exit('usage: verify-dual-pe-port.py {check-tree|check-image} <path>')

print('=== 双 PE 引擎护栏 (%s) ===' % mode)

if mode == 'check-tree':
    drv = root / 'target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtl_ax_ap'
    pe = root / 'target/linux/rtl9617c/pe'

    ok((drv / 'pe-core.c').is_file(), 'pe-core.c 存在（双 PE 核心）')
    core = txt(drv / 'pe-core.c')
    ok('static struct pe_probe *pe_engines[2]' in core,
       'pe_engines[2] 存在（rx=core0 / tx=core1 的双核实现）')
    ok('int pe_probe_alloc(struct pe_probe *pe, unsigned int slot, unsigned int core)' in core,
       'pe_probe_alloc 是三参数双核接口')
    ok('DUALPE-CACHED-ALIAS' in core, 'cached 别名修复已注入 pe-core.c')
    ok('static const u32 input[] = { 0x1fc0, 0x1000, 0x1100, 0x1200, 0x1300 };' in core,
       'ATU 只有 5 个窗口（物理 entry5 已移除）')
    ok('| 31 | index << 24 | BIT(31)' in core,
       'pe_probe_access 使用 31 掩码（5 窗口）')
    ok('index < 6' not in core, '没有残留 6 窗口循环（entries[5] 越界风险）')

    probe = txt(drv / 'pe_probe.h')
    ok('entries[5][7]' in probe, 'pe_probe.h entries 收缩为 5 窗口')

    entry = txt(pe / 'rtl9617c-radio-wd-entry.S')
    ok('lui $t0, 0x9fc0' in entry, 'PE 入口指令窗用 cached 0x9fc0')
    ok('ori $t0, $t0, 0xffff' in entry, 'PE 入口指令窗 64KiB')
    ok('lui $t9, 0x9fc0' in entry, 'PE 入口跳转 cached 别名')
    ok('lui $t9, 0x8fc0' not in entry and 'lui $t0, 0x0fc0' not in entry,
       '没有残留物理 IRAM 别名指令（lui 0x8fc0 / 0x0fc0）')

    power = txt(drv / 'power-tables.c')
    ok('rtl_ax_update32(io, 0xd208, 0x00300000, 0);' in power,
       '0xd208 厂商 TXPWR_LMT 位已清零')
    ok('rtl_ax_update32(io, 0xd21c, 0x00040000, 0);' in power,
       '0xd21c 厂商 TXPWR_LMT 位已清零')

    # 生成出的 PE 程序不能还是单 PE1 参考版
    pehdr = drv / 'pe-tx-code.h'
    ok(pehdr.is_file(), 'pe-tx-code.h 已由 PE 工具链现场生成')
    if pehdr.is_file():
        md5 = hashlib.md5(pehdr.read_bytes()).hexdigest()
        ok(md5 != '7eb49893f43b897bf03fa82ae2323984',
           'PE 程序不是单 PE1 参考版（md5 != 7eb49893）')
        print('  INFO  pe-tx-code.h md5=%s bytes=%d' % (md5, pehdr.stat().st_size))

else:  # check-image
    kos = list(root.rglob('rtl_ax_ap.ko'))
    ok(bool(kos), '镜像含 rtl_ax_ap.ko')
    if kos:
        data = kos[0].read_bytes()
        ok(b'pe_probe_alloc' in data,
           'rtl_ax_ap.ko 含全局 pe_probe_alloc（双 PE 核心已编入）')
        ok(b'pe_engines' in data or b'tyfza1-pe-probe' in data,
           '镜像含双核 pe 引擎/平台设备痕迹')

print('  DUALPE_VERIFY_OK=True checks=%d' % count)
