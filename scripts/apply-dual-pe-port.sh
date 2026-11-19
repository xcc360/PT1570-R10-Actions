#!/bin/bash
# PT1570-R10 双 PE (dual-PE) 引擎移植：对齐已验证 cached IRAM 别名。
#
# 背景（2026-11-19）：
#   lyq1996/rtl9617c-openwrt@20b4cf44 是真正的"双 PE core"驱动：
#     - pe-core.c: pe_engines[2] / pe_probe_alloc(pe, slot, core)
#     - rx.c 用 core0，tx.c 用 core1；ATU ioremap 按 core 偏移 0x100
#     - reset_mask = BIT(18+core) | BIT(20+core)
#   但它用**物理** CP3 别名 0x0fc0 / 32KiB 指令窗 / ATU entry5 填充，
#   这正是 dreamtekcat/PonWRT-TYFZA1 的 2bee260754 实测坏掉、并由
#   bfae5d6f2f revert 的方案：PE 不写 PEWD(0x50455744) -> 100ms 超时
#   -> -ETIMEDOUT(-110) -> 两张卡 probe 都失败。
#
#   已验证可用的单 PE1 参考版用**cached** 别名 0x9fc0 / 64KiB 指令窗 /
#   5 个 ATU 窗口 / entry0，PT1570 实机 probe 成功。
#
# 本脚本只把双 PE 的**寻址**对齐到已验证形态，保留双核本身
# （pe-core.c / 两 core 复位与 ATU 偏移 / rx=core0 tx=core1），
# 并清掉上游仍置 1 的厂商 TXPWR_LMT 位（0xd208/0xd21c）。
#
# 必须在 workflow 的 "Build PE firmware" **之前**执行：entry.S 会被现场
# 编译进 pe-tx-code.h，之后再改就来不及了。
set -euo pipefail

WRT="${WRT:-${GITHUB_WORKSPACE:-.}/wrt}"
PE_DIR="$WRT/target/linux/rtl9617c/pe"
DRV_DIR="$WRT/target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtl_ax_ap"

fail() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$PE_DIR" ] || fail "找不到 $PE_DIR"
[ -f "$PE_DIR/rtl9617c-radio-wd-entry.S" ] || fail "缺 rtl9617c-radio-wd-entry.S"
[ -f "$DRV_DIR/pe-core.c" ] || fail "缺 pe-core.c（dual-PE 资产不完整？）"

python3 - "$PE_DIR/rtl9617c-radio-wd-entry.S" "$DRV_DIR/pe-core.c" \
          "$DRV_DIR/power-tables.c" "$DRV_DIR/pe_probe.h" <<'PY'
import pathlib, sys

entry_s, pe_core_c, power_c, pe_probe_h = [pathlib.Path(p) for p in sys.argv[1:5]]


def edit(path, subs, tag):
    text = path.read_text(encoding='utf-8')
    if 'DUALPE-CACHED-ALIAS' in text:
        print('%s: %s already applied, skip' % (path.name, tag))
        return
    for old, new in subs:
        c = text.count(old)
        if c != 1:
            raise SystemExit('ERROR: %s 中锚点出现 %d 次（期望 1），tag=%s：%r'
                             % (path.name, c, tag, old[:90]))
        text = text.replace(old, new, 1)
    path.write_text(text, encoding='utf-8', newline='\n')
    print('%s: %s applied (%d anchors)' % (path.name, tag, len(subs)))


# ---- 1. PE 入口：物理 0x0fc0/32KiB -> cached 0x9fc0/64KiB ----
edit(entry_s, [
    ('    # The board\'s DSP uses28-bit CP3 addresses and a32KiB instruction window.\n',
     '    # DUALPE-CACHED-ALIAS: use the PT1570-verified cached IRAM alias.\n'
     '    # Physical 0x0fc0 / 32KiB was reverted upstream (no PEWD -> -110).\n'),
    ('    lui $t0, 0x0fc0\n', '    lui $t0, 0x9fc0\n'),
    ('    ori $t0, $t0, 0x7fff\n', '    ori $t0, $t0, 0xffff\n'),
    ('    # ATU entry5 supplies the physical28-bit fill/execution alias.\n'
     '    lui $t9, 0x8fc0\n',
     '    # DUALPE-CACHED-ALIAS: execution jumps to the cached alias,\n'
     '    # filled via ATU entry0 (same as the proven single-PE build).\n'
     '    lui $t9, 0x9fc0\n'),
    ('    sw $t9, 212($a0)\n', ''),
], 'cached IRAM alias')

# ---- 2. pe-core.c：6 窗口物理 entry5 -> 5 窗口 cached entry0 ----
edit(pe_core_c, [
    ('\t/* Stock DSP CP3 windows use28-bit addresses. Keep the reset alias,\n'
     '\t * and provide the same code at0x0fc00000 for instruction-memory fill. */\n'
     '\tstatic const u32 input[] = { 0x1fc0, 0x1000, 0x1100, 0x1200, 0x1300, 0x0fc0 };\n'
     '\tstatic const u32 output[] = { 0, 0xf430, 0xa040, 0xb040, 0xf700, 0 };\n',
     '\t/* DUALPE-CACHED-ALIAS: 5 CP3 windows with cached 0x9fc0 instruction\n'
     '\t * alias (upstream 6-window physical entry5 was reverted: no PEWD). */\n'
     '\tstatic const u32 input[] = { 0x1fc0, 0x1000, 0x1100, 0x1200, 0x1300 };\n'
     '\tstatic const u32 output[] = { 0, 0xf430, 0xa040, 0xb040, 0xf700 };\n'),
    ('\tfor (index = 0; index < 6; index++) {\n\t\twritel(input[index], pe->atu + 4);\n'
     '\t\twritel(index && index != 5 ? 0xfff0 : 0xffff, pe->atu + 8);\n'
     '\t\twritel(index && index != 5 ? output[index] : pe->dma >> 16, pe->atu + 12);\n',
     '\tfor (index = 0; index < 5; index++) {\n\t\twritel(input[index], pe->atu + 4);\n'
     '\t\twritel(index ? 0xfff0 : 0xffff, pe->atu + 8);\n'
     '\t\twritel(index ? output[index] : pe->dma >> 16, pe->atu + 12);\n'),
    ('\t\tret = pe_probe_access(pe, (pe->staging[0] & 255) | 63 | index << 24 | BIT(31));\n',
     '\t\tret = pe_probe_access(pe, (pe->staging[0] & 255) | 31 | index << 24 | BIT(31));\n'),
    ('\tfor (index = 0; index < 6; index++) {\n'
     '\t\tret = pe_probe_access(pe, (pe->staging[0] & 255) | index << 24 | BIT(30));\n',
     '\tfor (index = 0; index < 5; index++) {\n'
     '\t\tret = pe_probe_access(pe, (pe->staging[0] & 255) | index << 24 | BIT(30));\n'),
    ('\t\tfor (index = 0; index < 6; index++) {\n'
     '\t\t\tfor (i = 0; i < 7; i++)\n'
     '\t\t\t\twritel(pe->entries[index][i], pe->atu + 4 + i * 4);\n',
     '\t\tfor (index = 0; index < 5; index++) {\n'
     '\t\t\tfor (i = 0; i < 7; i++)\n'
     '\t\t\t\twritel(pe->entries[index][i], pe->atu + 4 + i * 4);\n'),
], '5-window cached ATU')

# ---- 3. pe_probe.h：entries[6][7] -> entries[5][7] ----
edit(pe_probe_h, [
    ('\tu32 reset_saved, ram_saved, staging[8], entries[6][7], reset_mask;\n',
     '\tu32 reset_saved, ram_saved, staging[8], entries[5][7], reset_mask;\n'
     '/* DUALPE-CACHED-ALIAS: 5 windows, physical entry5 alias removed. */\n'),
], 'entries[5]')

# ---- 4. 厂商 TXPWR_LMT 限制位：0xd208/0xd21c 清零（对齐 0.8.5 / 原厂） ----
text = power_c.read_text(encoding='utf-8')
if 'DUALPE-CACHED-ALIAS' in text:
    print('%s: txpower fix already applied, skip' % power_c.name)
else:
    subs = [
        ('\tif ((io->read32(io->ctx, 0xd208) & 0x00300000) != 0x00300000 ||\n'
         '\t    !(io->read32(io->ctx, 0xd21c) & 0x00040000))\n'
         '\t\tgoto mismatch;\n',
         '\t/* DUALPE-CACHED-ALIAS: power_limit MIB=0, do not cap below by-rate. */\n'
         '\tif ((io->read32(io->ctx, 0xd208) & 0x00300000) ||\n'
         '\t    (io->read32(io->ctx, 0xd21c) & 0x00040000))\n'
         '\t\tgoto mismatch;\n'),
        ('\trtl_ax_update32(io, 0xd208, 0x00300000, 0x00300000);\n'
         '\trtl_ax_update32(io, 0xd21c, 0x00040000, 0x00040000);\n'
         '\tif ((io->read32(io->ctx, 0xd208) & 0x00300000) != 0x00300000 ||\n'
         '\t    !(io->read32(io->ctx, 0xd21c) & 0x00040000))\n',
         '\trtl_ax_update32(io, 0xd208, 0x00300000, 0);\n'
         '\trtl_ax_update32(io, 0xd21c, 0x00040000, 0);\n'
         '\tif ((io->read32(io->ctx, 0xd208) & 0x00300000) ||\n'
         '\t    (io->read32(io->ctx, 0xd21c) & 0x00040000))\n'
         '\t\treturn -EIO;\n'),
    ]
    for old, new in subs:
        c = text.count(old)
        if c != 1:
            raise SystemExit('ERROR: %s 中功率锚点出现 %d 次（期望 1）：%r'
                             % (power_c.name, c, old[:90]))
        text = text.replace(old, new, 1)
    power_c.write_text(text, encoding='utf-8', newline='\n')
    print('%s: txpower vendor-limit bits cleared' % power_c.name)
PY

# ---- 强校验：双核保留 + cached 别名生效 + 不再有物理 entry5 ----
grep -q 'DUALPE-CACHED-ALIAS' "$PE_DIR/rtl9617c-radio-wd-entry.S" \
  || fail "entry.S 未见 cached 别名标记"
grep -q 'lui \$t0, 0x9fc0' "$PE_DIR/rtl9617c-radio-wd-entry.S" \
  || fail "entry.S 指令窗未切到 cached 0x9fc0"
! grep -q 'lui \$t9, 0x8fc0' "$PE_DIR/rtl9617c-radio-wd-entry.S" \
  || fail "entry.S 仍跳物理别名 0x8fc0"
grep -q 'pe_engines\[2\]' "$DRV_DIR/pe-core.c" \
  || fail "pe-core.c 不再是双 PE 引擎（pe_engines[2] 缺失）"
grep -q 'pe_probe_alloc(struct pe_probe \*pe, unsigned int slot, unsigned int core)' "$DRV_DIR/pe-core.c" \
  || fail "pe-core.c 丢失三参数 pe_probe_alloc（双核接口）"
! grep -q '0x0fc0 }' "$DRV_DIR/pe-core.c" \
  || fail "pe-core.c 仍有物理 entry5 别名 0x0fc0"
grep -q 'rtl_ax_update32(io, 0xd208, 0x00300000, 0);' "$DRV_DIR/power-tables.c" \
  || fail "power-tables.c 0xd208 限制位未清零"

echo "DUALPE_PORT_OK=True (dual core kept, cached 0x9fc0 alias, 5 ATU windows, txpwr unclamped)"
