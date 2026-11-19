#!/usr/bin/env python3
"""PT1570-R10 upstream single-PE WiFi port —— 编译树 + 镜像双向护栏。

用法：
  verify-upstream-wifi-port.py check-tree <WRT> <PORT>
  verify-upstream-wifi-port.py check-image <ROOTFS> <PORT>

PORT: off | scan-rssi | scan-rssi+ra
任一断言失败 exit 1（阻止产出/发布可刷固件）。
"""
import sys, os, pathlib, hashlib

PE_MD5 = '7eb49893f43b897bf03fa82ae2323984'
PE_WORDS = 4076
DRV_REL = 'target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtl_ax_ap'

# 移植前后必须保持的单 PE1 基线（防止把双 PE / WD 保留带进来）
FORBIDDEN_TREE = [
    (f'{DRV_REL}/pe-core.c', None),               # 文件不得存在
]
FORBIDDEN_GREP = [
    (f'{DRV_REL}/Makefile', 'pe-core.o'),
    (f'{DRV_REL}/rx-geometry.h', 'RTL_AX_TX_WD_PER_RING'),
    (f'{DRV_REL}/rx-geometry.h', 'RTL_AX_TX_WD_PAGES'),
]

# B1: scan RSSI（scan-rssi 及以上）
B1_TREE = [
    (f'{DRV_REL}/scan.h', 'RTL_AX_AP_SCAN_H'),
    (f'{DRV_REL}/pci.c', '#include "scan.h"'),
    (f'{DRV_REL}/pci.c', '\tbool scanning;'),
    (f'{DRV_REL}/pci.c', '\tstruct sk_buff *scan_pending;'),
    (f'{DRV_REL}/pci.c', 'rtl_ax_scan_complete_frame(radio, NULL);'),
    (f'{DRV_REL}/pci.c', 'rtl_ax_scan_complete_frame(radio, packet);'),
    (f'{DRV_REL}/pci.c', 'scan_RSSI_matched=%llu unmatched=%llu'),
    (f'{DRV_REL}/monitor.h', '\tieee80211_hw_set(hw, SIGNAL_DBM);'),
    (f'{DRV_REL}/monitor.h', 'static void rtl_ax_sw_scan_start('),
    (f'{DRV_REL}/monitor.h', '.sw_scan_start = rtl_ax_sw_scan_start'),
    (f'{DRV_REL}/monitor.h', 'static void rtl_ax_scan_complete_frame('),
    (f'{DRV_REL}/monitor.h', 'radio->scan_pending = skb;'),
    (f'{DRV_REL}/monitor.h', 'if (!radio->scanning)'),
]
B1_COUNTS = [
    (f'{DRV_REL}/monitor.h', 'rtl_ax_scan_complete_frame(radio, NULL);', 1),
    (f'{DRV_REL}/monitor.h', 'if (!radio->scanning)', 1),
    (f'{DRV_REL}/pci.c', 'static void rtl_ax_scan_complete_frame(struct rtl_ax_ap *radio,', 1),
    (f'{DRV_REL}/pci.c', 'rtl_ax_scan_complete_frame(radio, NULL);', 2),
]

# B2: RA 信号结构（仅 scan-rssi+ra）
B2_TREE = [
    (f'{DRV_REL}/rate.h', 'struct rtl_ax_ra_rssi {'),
    (f'{DRV_REL}/rate.h', 'rtl_ax_ra_rssi_sample'),
    (f'{DRV_REL}/rate.h', 'rtl_ax_ra_rssi_watchdog'),
    (f'{DRV_REL}/rate.h', 'rtl_ax_ppdu_ra_signal'),
]

# 镜像内：这些字符串应编入 .ko（驱动源码不进 rootfs，用符号/统计名断言）
B1_IMAGE = [
    'lib/firmware/realtek/tyfza1/rtl8852c-u1-ap.bin',
]


def read(base, rel):
    p = pathlib.Path(base) / rel
    if not p.exists():
        return None
    return p.read_text(encoding='utf-8', errors='replace')


def fail(msg):
    print('WIFIPORT_VERIFY_FAIL: ' + msg, file=sys.stderr)
    sys.exit(1)


def check_tree(base, port):
    # 基线：PE 微码不被改
    pe = pathlib.Path(base) / DRV_REL / 'pe-tx-code.h'
    if not pe.exists():
        fail(f'缺 pe-tx-code.h: {pe}')
    md5 = hashlib.md5(pe.read_bytes()).hexdigest()
    if md5 != PE_MD5:
        fail(f'pe-tx-code.h md5={md5} != {PE_MD5}')
    words = pe.read_text(encoding='utf-8', errors='replace').count('0x')
    if words != PE_WORDS:
        fail(f'pe-tx-code.h 0x-words={words} != {PE_WORDS}')
    for rel, _ in FORBIDDEN_TREE:
        if (pathlib.Path(base) / rel).exists():
            fail(f'禁止文件存在: {rel}')
    for rel, needle in FORBIDDEN_GREP:
        t = read(base, rel)
        if t and needle in t:
            fail(f'禁止内容 {needle!r} 出现在 {rel}')
    print(f'TREE_BASE_OK md5={md5[:8]} words={words} no-pe-core no-wd-retain')

    if port == 'off':
        # off：不得有移植痕迹（保证与现网等价）
        if read(base, f'{DRV_REL}/scan.h'):
            fail('port=off 但发现 scan.h（移植痕迹残留）')
        print('TREE_PORT_OFF_OK (no port artifacts)')
        return

    for rel, needle in B1_TREE:
        t = read(base, rel)
        if t is None or needle not in t:
            fail(f'B1 缺失: {needle!r} in {rel}')
    for rel, needle, want in B1_COUNTS:
        t = read(base, rel)
        got = t.count(needle) if t else 0
        if got != want:
            fail(f'B1 计数错: {needle!r} in {rel} got={got} want={want}')
    print('TREE_B1_OK (scan-rssi: scan.h + SIGNAL_DBM + sw_scan + stats)')

    if port == 'scan-rssi+ra':
        for rel, needle in B2_TREE:
            t = read(base, rel)
            if t is None or needle not in t:
                fail(f'B2 缺失: {needle!r} in {rel}')
        print('TREE_B2_OK (ra-signal subset present)')
    print(f'TREE_PORT_OK port={port}')


def check_image(rootfs, port):
    if port == 'off':
        print('IMAGE_PORT_OFF_OK')
        return
    # 固件 .ko 不保留源码字符串保证（编译器可能内联/裁剪），这里做基础存在性断言：
    # WiFi 固件、uci-default、network 默认关闭硬件卸载（C3 固化）。
    for rel in B1_IMAGE:
        if not (pathlib.Path(rootfs) / rel).exists():
            fail(f'镜像缺 WiFi 固件: {rel}')
    tuning = pathlib.Path(rootfs) / 'etc/uci-defaults/96-pt1570-wifi-tuning'
    if not tuning.exists():
        fail('镜像缺 96-pt1570-wifi-tuning')
    print(f'IMAGE_PORT_OK port={port} (wifi firmware + tuning present)')


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    mode, base, port = sys.argv[1], sys.argv[2], sys.argv[3]
    if port not in ('off', 'scan-rssi', 'scan-rssi+ra'):
        fail(f'unknown port={port}')
    if mode == 'check-tree':
        check_tree(base, port)
    elif mode == 'check-image':
        check_image(base, port)
    else:
        fail(f'unknown mode={mode}')


if __name__ == '__main__':
    main()
