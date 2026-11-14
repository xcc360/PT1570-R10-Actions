#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CU U-Boot 产物校验：GPT/BL2/BL31 必须与本机 stock 一致，BL33 必须被替换。"""
import sys, json, struct, hashlib
from pathlib import Path

board_json = Path(sys.argv[1])
image = Path(sys.argv[2]).read_bytes()
stock = Path(sys.argv[3]).read_bytes()
cfg = json.loads(board_json.read_text())
lay = cfg['layout']
slot0, slot1 = lay['fip_slot_offsets']
cap = lay['fip_slot_capacity']
magic = bytes.fromhex(lay['toc_magic_hex'])
hsz, esz = lay['toc_header_size'], lay['toc_entry_size']
uuid_map = {u: r for r, u in cfg['fip_uuids'].items()}


def uuid_of(raw):
    a, b, c = struct.unpack('<IHH', raw[:8])
    d = raw[8:16]
    return '%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x' % (
        a, b, c, *d)


def parse(d, base):
    slot = d[base:base + cap]
    assert slot[:4] == magic[:4], 'FIP ToC magic missing at 0x%x' % base
    out, cur = {}, hsz
    while cur < 0x400:
        raw = slot[cur:cur + esz]
        if raw[:16] == bytes(16):
            break
        out[uuid_map.get(uuid_of(raw[:16]), uuid_of(raw[:16]))] = \
            struct.unpack_from('<QQ', raw, 16)
        cur += esz
    return out


def payload(d, base, e, role):
    off, size = e[role]
    return d[base + off:base + off + size]


def ok(cond, msg):
    print(('  PASS  ' if cond else '  FAIL  ') + msg)
    if not cond:
        sys.exit(1)


ok(len(image) == lay['boot_size'] == len(stock), 'boot 镜像尺寸 2 MiB')
ok(image[:slot0] == stock[:slot0],
   'GPT 区 0x0-0x%x 与联通 stock 完全一致（电信版刷不进的根因）' % slot0)
tail = max(slot0, slot1) + cap
ok(image[tail:] == stock[tail:], '保留尾部 0x%x 与联通 stock 一致' % tail)
e0, es = parse(image, slot0), parse(stock, slot0)
e1 = parse(image, slot1)
ok(e0 == e1, '两个 FIP 槽 ToC 一致')
for role in ('tb_fw', 'soc_fw'):
    ok(payload(image, slot0, e0, role) == payload(stock, slot0, es, role),
       '%s（BL2/BL31）与联通 stock 逐字节一致' % role)
ok(payload(image, slot0, e0, 'nt_fw') != payload(stock, slot0, es, 'nt_fw'),
   'BL33 已被开源 U-Boot 替换')
ok(hashlib.sha256(stock).hexdigest() == cfg['stock_sha256'],
   'stock sha256 与 board JSON 记录一致')
print('  CU_BOOT_OK=True')
