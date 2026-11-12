#!/bin/bash
# PT1570-R10 WiFi：把 rtl_ax_ap 驱动整体替换为已实测可用的 PT1570 版本。
#
# 真机（run19 initramfs）症状：
#   rtl_ax_ap: AP startup: powered=1 prepared=1 firmware=0 ...
#   rtl_ax_ap: error -ETIMEDOUT: AP identity or firmware startup failed
#   rtl_ax_ap: probe with driver rtl_ax_ap failed with error -110
#   两张卡（8852C / 8192XB）都失败；PE mailbox 等不到 0x50455744 ("PEWD")。
#
# 根因：lyq1996 上游（我们云编译锁定的 20b4cf4）里的 PE 引擎实现，正是
# dreamtekcat/PonWRT-TYFZA1 pt1570 分支在 2026-10-13 实测坏掉并 revert 的
# 那个方案：
#   commit 2bee260754 "Load PE code into IRAM and use physical CP3 memory windows"
#   commit bfae5d6f2f Revert "Load PE code into IRAM and ..."
# 上游 pe/rtl9617c-radio-wd-entry.S 用 0x0fc0 / jr 0x8fc00400 的物理 IRAM 别名，
# 并由 pe-core.c 多出来的第 6 个 ATU 窗口（input[5]=0x0fc0）配合；
# 参考（可用）版用 0x9fc0 cached 别名、ATU entry0、5 个窗口、单 PE1 引擎。
# PE 程序跳不到正确地址 -> 不写 PEWD -> 100ms 超时 -> -110 -> probe 失败。
#
# 上游是"双 PE core"架构（rx.c 用 core0、tx.c 用 core1，pe-core.c 按
# core 索引 pe_engines[2]），参考是单 PE1 引擎（pe_probe.h 内联实现，
# Makefile 不编 pe-core.o），两者接口不兼容，因此必须整套替换，不能只换
# 一个头文件。上游内核补丁集（patches-6.18/100~213）与配置
# （CONFIG_RTL_AX_AP=m）与参考分支同源，配套设施齐全。
#
# 本步骤必须在 "Build PE firmware"（会用上游 pe/ 现场编译出坏版
# pe-tx-code.h）之后、"Configure" 之前执行，用参考版头文件覆盖之。
set -euo pipefail

ASSETS="${ASSETS:-$GITHUB_WORKSPACE}"
WRT="${WRT:-$ASSETS/wrt}"
SRC="$ASSETS/board/wifi/rtl_ax_ap"
DST="$WRT/target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtl_ax_ap"

fail() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$SRC" ] || fail "找不到 $SRC"
[ -d "$DST" ] || fail "找不到上游驱动目录 $DST（上游目录结构变了？）"
n=$(find "$SRC" -maxdepth 1 -type f | wc -l)
[ "$n" -ge 60 ] || fail "参考驱动文件数 $n < 60，资产不完整"

echo "=== overlay PT1570 WiFi driver ($n files) ==="
cp -a "$SRC/." "$DST/"
# 上游独有的 pe-core.c 不属于参考实现；参考 Makefile 不引用它，留着只会混淆
rm -f "$DST/pe-core.c"

# ---- 分段诊断打点：万一仍失败，一次就能定位卡在 PE alloc / 0x101c / PE start ----
python3 - "$DST/tx.c" "$DST/pci.c" <<'PY'
import pathlib, sys

def patch(path, subs):
    p = pathlib.Path(path)
    text = p.read_text(encoding='utf-8')
    if 'PT1570-DIAG' in text:
        print('%s: diag already present, skip' % p.name)
        return
    for old, new in subs:
        c = text.count(old)
        if c != 1:
            raise SystemExit('ERROR: %s 中锚点出现 %d 次（期望 1）：%r'
                             % (p.name, c, old[:70]))
        text = text.replace(old, new, 1)
    p.write_text(text, encoding='utf-8', newline='\n')
    print('%s: diag injected (%d anchors)' % (p.name, len(subs)))

patch(sys.argv[1], [
    ('\t\tret = pe_probe_alloc(&tx->pe, pdev->device == 0xc852 ? 0 : 1);\n'
     '\t\tif (ret) goto release;',
     '\t\tret = pe_probe_alloc(&tx->pe, pdev->device == 0xc852 ? 0 : 1);\n'
     '\t\tdev_info(&pdev->dev, "PT1570-DIAG stage=pe_alloc ret=%d\\n", ret);\n'
     '\t\tif (ret) goto release;'),
    ('\tret = io->poll32(io->ctx, 0x101c, RTL_AX_TX_STOP_MASK, 0, 10, 100000, &last);\n'
     '\tif (ret)\n\t\tgoto release;',
     '\tret = io->poll32(io->ctx, 0x101c, RTL_AX_TX_STOP_MASK, 0, 10, 100000, &last);\n'
     '\tdev_info(&pdev->dev, "PT1570-DIAG stage=tx_stop_poll ret=%d last=%08x\\n", ret, last);\n'
     '\tif (ret)\n\t\tgoto release;'),
    ('\t\tret = rtl_ax_tx_pe_start(tx);\n\t\tif (ret) goto release;',
     '\t\tret = rtl_ax_tx_pe_start(tx);\n'
     '\t\tdev_info(&pdev->dev, "PT1570-DIAG stage=pe_start ret=%d\\n", ret);\n'
     '\t\tif (ret) goto release;'),
])

patch(sys.argv[2], [
    ('\tret = rtl_ax_ring_prepare(radio);\n\tif (ret)\n\t\treturn ret;',
     '\tret = rtl_ax_ring_prepare(radio);\n'
     '\tdev_info(&radio->pdev->dev, "PT1570-DIAG stage=ring_prepare ret=%d\\n", ret);\n'
     '\tif (ret)\n\t\treturn ret;'),
])
PY

# ---- 强校验：确保覆盖生效、且确实是"已 revert 的 PE 实现" ----
EXP_PE_MD5=7eb49893f43b897bf03fa82ae2323984
got=$(md5sum "$DST/pe-tx-code.h" | cut -d' ' -f1)
[ "$got" = "$EXP_PE_MD5" ] \
  || fail "pe-tx-code.h md5=$got，期望 $EXP_PE_MD5（参考版 PE 程序未生效）"
! grep -q 'pe-core\.o' "$DST/Makefile" \
  || fail "Makefile 仍引用 pe-core.o（上游双 PE core 架构残留）"
grep -q 'static int pe_probe_alloc(struct pe_probe \*pe, unsigned int slot)' "$DST/pe_probe.h" \
  || fail "pe_probe.h 不是参考的单引擎内联实现"
grep -q 'PE_PROBE_RESET (BIT(19) | BIT(21))' "$DST/pe_probe.h" \
  || fail "pe_probe.h 缺 PE1 复位掩码（拿到的是别的实现？）"
! grep -q 'pe_probe_alloc(&tx->pe.*,[[:space:]]*[01])' "$DST/tx.c" \
  || fail "tx.c 仍是三参数 pe_probe_alloc（上游双 core 调用残留）"
[ ! -e "$DST/pe-core.c" ] || fail "pe-core.c 未被删除"
grep -q 'PT1570-DIAG' "$DST/tx.c" && grep -q 'PT1570-DIAG' "$DST/pci.c" \
  || fail "分段诊断打点未注入"
# 参考版 PE 程序是 4076 个 u32；上游现场编译的是 4227 个
words=$(grep -c '0x' "$DST/pe-tx-code.h")
[ "$words" = 4076 ] || fail "pe-tx-code.h 指令数 $words != 4076"

echo "WIFI_DRIVER_OVERLAY_OK=True (PE IRAM revert, 4076 words, PE1 single-engine, diag on)"
