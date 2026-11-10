#!/bin/bash
# 给上游 rtl_ax_ap 驱动注入"只读寄存器打点"，用于定位 WiFi AP 启动卡在哪一步。
#
# 背景（2026-11-10 真机）：
#   rtl_ax_ap 0000:01:00.0: AP startup: powered=1 prepared=1 firmware=0
#                            memory=0 dmac=0 cmac=0 phy=0 fem=0
#   rtl_ax_ap 0000:01:00.0: error -ETIMEDOUT: AP identity or firmware startup failed
# 两个 radio（8852C / 8192XB）在同一个点失败，且 118ms 的耗时与
# rtl_ax_h2c_ring_configure() 里那个 100ms 的 0x101c 轮询高度吻合；
# 由于 rtl_ax_load_firmware() 里 "AP download failed" 那条 dev_err 没有出现，
# 说明失败发生在 ring_prepare（HCI/HAXI 还没 idle），而不是 WCPU 下载本身。
#
# 本脚本只加 dev_info 读点，不改任何写序列、不改控制流；只在
# workflow_dispatch 的 wifi_diag=true 时执行。幂等：已打过就跳过。
set -euo pipefail

WRT="${WRT:-}"
[ -n "$WRT" ] || WRT="$(pwd)"
DRV="$WRT/target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtl_ax_ap"
PCI="$DRV/pci.c"

[ -f "$PCI" ] || { echo "ERROR: 找不到驱动源码 $PCI" >&2; exit 1; }

# ---- /dev/mem 必须写进 target 的**内核** config 文件 ----
# run #13 证明把 CONFIG_DEVMEM 写进顶层 .config 会被 make defconfig 静默丢掉
# （该符号不在顶层 Kconfig 树里），Configure 断言随即失败。
KCFG="$WRT/target/linux/rtl9617c/config-6.18"
[ -f "$KCFG" ] || { echo "ERROR: 找不到内核配置 $KCFG" >&2; exit 1; }
if ! grep -q '^CONFIG_DEVMEM=y$' "$KCFG"; then
  sed -i '/^CONFIG_DEVMEM=/d; /^# CONFIG_DEVMEM is not set$/d' "$KCFG"
  printf 'CONFIG_DEVMEM=y\n' >> "$KCFG"
  echo "kernel config: + CONFIG_DEVMEM=y ($KCFG)"
fi
grep -q '^CONFIG_DEVMEM=y$' "$KCFG" \
  || { echo "ERROR: CONFIG_DEVMEM 未写入内核配置" >&2; exit 1; }

if grep -q 'rtl_ax_diag_dump' "$PCI"; then
  echo "WIFI_DIAG_SKIP=True (driver already patched)"
  echo "WIFI_DIAG_OK=True"
  exit 0
fi

python3 - "$PCI" <<'PY'
import io
import sys

path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()

DIAG = r'''/* PT1570 CI 诊断打点（wifi_diag=true 时注入）：只读寄存器，无副作用。
 * 用于定位 rtl_ax_ap probe 卡在 HCI/HAXI、WCPU 还是 FW 下载。 */
static void rtl_ax_diag_dump(struct rtl_ax_ap *radio, const char *tag)
{
	dev_info(&radio->pdev->dev,
		 "DIAG[%s] FUNC=%08x PLATFORM=%08x CHIP=%02x"
		 " 02e4=%08x 1000=%08x 1004=%08x 1010=%08x 1014=%08x"
		 " 1018=%08x 101c=%08x 1204=%08x 1280=%08x 1700=%08x"
		 " 7880=%08x 8400=%08x 8404=%08x 8c08=%08x 8d00=%08x"
		 " 9008=%08x 9100=%08x 9110=%08x 9114=%08x"
		 " WCPU_CONTROL=%08x 01e8=%08x 01a4=%08x\n",
		 tag,
		 rtl_ax_read32(radio, 0x0008), rtl_ax_read32(radio, 0x0088),
		 rtl_ax_read8(radio, RTL_AX_CHIP),
		 rtl_ax_read32(radio, 0x02e4), rtl_ax_read32(radio, 0x1000),
		 rtl_ax_read32(radio, 0x1004), rtl_ax_read32(radio, 0x1010),
		 rtl_ax_read32(radio, 0x1014), rtl_ax_read32(radio, 0x1018),
		 rtl_ax_read32(radio, 0x101c), rtl_ax_read32(radio, 0x1204),
		 rtl_ax_read32(radio, 0x1280), rtl_ax_read32(radio, 0x1700),
		 rtl_ax_read32(radio, 0x7880), rtl_ax_read32(radio, 0x8400),
		 rtl_ax_read32(radio, 0x8404), rtl_ax_read32(radio, 0x8c08),
		 rtl_ax_read32(radio, 0x8d00), rtl_ax_read32(radio, 0x9008),
		 rtl_ax_read32(radio, 0x9100), rtl_ax_read32(radio, 0x9110),
		 rtl_ax_read32(radio, 0x9114),
		 rtl_ax_read32(radio, RTL_AX_WCPU_CONTROL),
		 rtl_ax_read32(radio, 0x01e8), rtl_ax_read32(radio, 0x01a4));
}

'''

PATCHES = [
    # A. 在 load_firmware 之前插入打点函数
    (
        "static int rtl_ax_load_firmware(struct rtl_ax_ap *radio, const struct firmware *fw)\n",
        DIAG + "static int rtl_ax_load_firmware(struct rtl_ax_ap *radio, const struct firmware *fw)\n",
    ),
    # B. ring_prepare 前后
    (
        "\tint ret;\n\n"
        "\tret = rtl_ax_ring_prepare(radio);\n"
        "\tif (ret)\n"
        "\t\treturn ret;\n",
        "\tint ret;\n\n"
        "\trtl_ax_diag_dump(radio, \"enter\");\n"
        "\tret = rtl_ax_ring_prepare(radio);\n"
        "\tif (ret) {\n"
        "\t\trtl_ax_diag_dump(radio, \"ring_prepare-fail\");\n"
        "\t\treturn ret;\n"
        "\t}\n"
        "\trtl_ax_diag_dump(radio, \"ring_prepare-ok\");\n",
    ),
    # C. WCPU enable + FW 下载之后（这条分支原本不打日志，正是现在的盲区）
    (
        "\trtl_ax_hci_pause(&radio->io);\n"
        "\tpci_clear_master(radio->pdev);\n"
        "\tif (ret) {\n",
        "\trtl_ax_hci_pause(&radio->io);\n"
        "\tpci_clear_master(radio->pdev);\n"
        "\trtl_ax_diag_dump(radio, ret ? \"wcpu+download-fail\" : \"wcpu+download-ok\");\n"
        "\tif (ret) {\n",
    ),
    # D. probe 里 wcpu_stop / download_prepare 前后
    (
        "\trtl_ax_wcpu_stop(&radio->io);\n"
        "\tret = rtl_ax_download_prepare(&radio->io);\n"
        "\tif (ret)\n"
        "\t\tgoto release;\n",
        "\trtl_ax_diag_dump(radio, \"pre-wcpu_stop\");\n"
        "\trtl_ax_wcpu_stop(&radio->io);\n"
        "\trtl_ax_diag_dump(radio, \"post-wcpu_stop\");\n"
        "\tret = rtl_ax_download_prepare(&radio->io);\n"
        "\tif (ret) {\n"
        "\t\trtl_ax_diag_dump(radio, \"download_prepare-fail\");\n"
        "\t\tgoto release;\n"
        "\t}\n"
        "\trtl_ax_diag_dump(radio, \"download_prepare-ok\");\n",
    ),
]

for i, (old, new) in enumerate(PATCHES, 1):
    n = src.count(old)
    if n != 1:
        sys.exit("ERROR: 第 %d 个锚点命中 %d 次（期望 1 次），上游驱动已变动，"
                 "请重新核对 scripts/patch-wifi-diag.sh" % (i, n))
    src = src.replace(old, new, 1)

io.open(path, "w", encoding="utf-8", newline="\n").write(src)
print("patched %s (4 anchors)" % path)
PY

grep -q 'rtl_ax_diag_dump(radio, "ring_prepare-fail")' "$PCI" \
  || { echo "ERROR: 打点未落盘" >&2; exit 1; }

echo "WIFI_DIAG_OK=True"
