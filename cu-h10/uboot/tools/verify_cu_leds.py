#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Static guard for the CU U-Boot status-lamp board description.

Runs before any compilation, so a bad lamp table can never reach the device:
one pin outside GPIO bank 0, or pin 8 (the reset key), makes
rtl9617c_gpio_group_select()/the failsafe LED runner misbehave and leaves the
panel dark again.

Usage:
    verify_cu_leds.py <cu-desc-2p5g.c> [upstream-ct-desc-2p5g.c]
"""
import pathlib
import re
import sys

EXPECTED = {
    0: True,    # LED_EPHY3 (PT1500/4GE lan3)
    1: True,    # LED_EPHY2
    2: True,    # LED_PPP_G / 2p5g usb1 — both maps agree on active-low
    3: True,    # LED_EPHY1 / 2p5g lan2 — both agree
    4: True,    # LED_EPHY0 / 2p5g lan3 — both agree
    7: False,   # usb0 (active high)
    9: True,    # LED_PON
    10: True,   # LED_LOS
    11: False,  # LED_PWR_G / 2p5g lan0 — both agree on active-high
    12: False,  # LED_FXS  / 2p5g lan1 — both agree on active-high
}
RESET_PIN = 8
BANK_PINS = 32


def ok(cond, msg):
    if not cond:
        raise SystemExit('ERROR: ' + msg)
    print('  OK   ' + msg)


def main():
    cu = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')

    # lamp table: { .pin = N[, .active_low = true] }, ignoring comments
    body = re.search(r'static const struct rtk_led\s+\w+\[\]\s*=\s*\{(.*?)\n\};',
                     cu, re.S)
    ok(body is not None, '找到 rtk_led 灯表')
    entries = []
    for line in body.group(1).splitlines():
        line = line.split('/*')[0].strip()
        m = re.search(r'\{\s*\.pin\s*=\s*(\d+)', line)
        if not m:
            continue
        entries.append((int(m.group(1)), '.active_low' in line))

    ok(len(entries) == 10, '灯数 = 10（PT1500 面板序 + 2p5g 并集）')
    pins = [p for p, _ in entries]
    ok(len(set(pins)) == len(pins), '无重复 pin')
    ok(all(p < BANK_PINS for p in pins), '全部 pin < 32（同一 GPIO bank 0）')
    ok(RESET_PIN not in pins, '未占用 pin 8（reset 键）')
    ok(dict(entries) == EXPECTED, 'pin/极性与两套映射的并集逐项一致')
    ok('4' in [str(p) for p in pins], '含 pin 4（2p5g lan3 / CT desc 曾列）')

    ok('.name = "Youhua PT1570-H10-CU"' in cu, '机型标识为 CU')
    ok('.ports = "2.5GE + 3×GE"' in cu, '恢复页网口描述 = 2.5GE + 3×GE')
    ok(re.search(r'\.reset_pin\s*=\s*8\s*,', cu) is not None, 'reset_pin = 8')
    ok('.reset_active_low = true' in cu, 'reset 低有效')
    ok('ARRAY_SIZE(' in cu and 'nr_lamps' in cu, 'nr_lamps 使用 ARRAY_SIZE')

    if len(sys.argv) > 2:
        ct = pathlib.Path(sys.argv[2]).read_text(encoding='utf-8')
        ok(ct.count('.name = "Youhua PT1570-H10-CT",') == 1,
           '上游 CT desc 名称锚点唯一（覆盖前）')
        ok(re.search(r'\{\s*\.pin\s*=\s*0\s*,', ct) is not None,
           '上游 CT desc 仍是旧的 4GE 映射（可安全整体覆盖）')

    print('CU_LEDS_OK=True lamps=10 pins=%s (bank 0, reset pin 8 spared)'
          % ','.join(str(p) for p in pins))


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    main()
