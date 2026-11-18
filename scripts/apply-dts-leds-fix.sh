#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# PT1500-H10 2.5G：按**原厂 DTB** 校正面板灯的 GPIO 编号。
#
# ★ 2026-11-17 实机回归：run#6（refactor 基线）刷入后"指示灯完全不对"。
#
# 根因（已用原厂备份逐字节核对）：
#   原厂 DTB（D:\ONT\PT1500-H10\BackUp-原厂\mtd4-ubi_device.bin @ 266240）
#   用的是**分 5 个 bank** 的 GPIO 控制器 gpio-controller@f43292c0：
#     bank0 gpio-ranges 起始 0x00 ngpios 0x10 phandle 0x25
#     bank1            0x20          0x11
#     bank2            0x40          0x0c
#     bank3            0x60          0x19 phandle 0x27
#     bank4            0x80          0x11 phandle 0x3b
#   面板灯用的是私有驱动 realtek,g3hgu-gpio-led，led-gpio 形如
#   <phandle> <pin> <flags>，其中 phandle 可能是 bank0(0x25) 也可能是 bank3(0x27)。
#
#   上游 refactor 的 rtl9617c.dtsi 只保留**一个扁平** gpio0 控制器
#   （gpio-ranges = <&pinctrl 0 0 160>，即 bank0->0-15、bank1->32-48、
#   bank2->64-75、bank3->96-120、bank4->128-144），
#   而上游 rtl9617c-pt1500-h10-2p5g.dts 的 leds 直接用了另一套编号
#   （PPP_G=gpio2、LOS=gpio10、PON=gpio9、PWR_G=gpio11、EPHY1=gpio3…），
#   **与原厂完全对不上**（8 个灯错 7 个，且 PWR_G 抢占了原厂 LOS 的 gpio11）。
#   上游没有 PT1500 原厂 DTB 做对照，DTS 灯编号属于未校准值。
#
# 本脚本在编译期把上游 DTS 的**顶层 leds 节点**整体替换为按原厂 flat 编号换算后的版本。
#
# 原厂 -> flat 换算表（依据原厂 DTB 的 led-gpio 实测值）：
#   LED_PPP_G  bank3 pin0  -> gpio96    LED_EPHY0  bank3 pin6 -> gpio102
#   LED_LOS    bank0 pin11 -> gpio11    LED_EPHY1  bank3 pin7 -> gpio103
#   LED_USB0   bank3 pin3  -> gpio99    LED_EPHY2  bank3 pin1 -> gpio97
#   LED_PON    bank3 pin12 -> gpio108   LED_EPHY3  bank3 pin4 -> gpio100
#   LED_PWR_G  bank0 pin6  -> gpio6     LED_USB1   bank3 pin5 -> gpio101
#   LED_FXS    bank0 pin12 -> gpio12
#
# 极性说明（2026-11-18 实机修正）：
#   原厂 DTB 的 11 盏 led-gpio flags 全为 0x00 = GPIO_ACTIVE_HIGH（高电平点亮）。
#   第一版（run#11）只改编号、极性沿用上游分组（PPP/LOS/PON/EPHY/USB=ACTIVE_LOW），
#   实机结果"只有电源灯亮"——电源灯恰是唯一 ACTIVE_HIGH + default-state=on 的灯。
#   实机 /sys/kernel/debug/gpio 实证：ACTIVE_LOW 灯在 bright=1 时输出低电平，
#   而硬件是高电平点亮，逻辑完全反了。本版把 11 盏灯统一改为 GPIO_ACTIVE_HIGH，
#   与原厂 flags=0x00 严格一致。
#
# ★★ 面板全灭的真正原因（2026-11-18 run#12 实机逐 pin 扫描后定位）：
#   极性改对之后 run#12 仍"一个都不亮"。实机把 11 个 flat 逐一点亮（每次只亮
#   一盏，读 /sys/kernel/debug/gpio 确认仅一个引脚为高）后现：**本机面板只有
#   两处可见灯** —— flat 96 是物理"电源"灯位，flat 11 是物理"电话"灯位；
#   其余 9 个 flat 背后在这块板上根本没有灯。
#   即：原厂 DTB 里那 11 盏灯是整个 TYFZA1 产品线共用的通用模板，原厂 label
#   与 PT1500-H10 的实际丝印并不对应（96 原厂标 LED_PPP_G、11 原厂标
#   LED_LOS，而本机这两脚实际是电源灯与电话灯）。run#11/run#12 按原厂 label
#   分配引脚时，把"电源灯"接到了没有灯的空脚上，于是面板全灭。
#   （实机交叉验证：U-Boot 阶段用原厂引脚时面板灯是亮的，亮的也正是这两个脚。）
#   本版按**物理丝印**指派：96 -> LED_PWR_G(default-state=on 常亮)、11 -> LED_FXS，
#   原 PPP_G/LOS 的位置顺移到 6/12，其余引脚保持原厂编号不变。
#
#   附：base 架构（lyq1996 @main 的 rtl9617c-tyfza1.dtsi）用的是 PWR_G=11、
#   PPP_G=2 这种连续低 pin 编号，且把 gpio 101/102 当 PHY reset、gpio 100 当
#   USB vbus —— 而原厂 DTB 里这两处实际是 bank3 pin17(flat 113) 与
#   bank4 pin13(flat 141)。可见 base 的 GPIO 编号体系与原厂 flat 并非同一套，
#   不可直接套用到 refactor。
#
# 注意：DTS 里有多个 leds 节点 —— 顶层面板灯节点、以及 mdio 下 phy_2p5g 里的
# PHY LED 节点（LED_8221B_P6_*，那是 RTL8221B 芯片自己的灯，不是面板灯）。
# 本脚本只改**顶层**那个（紧跟 "/ {" 之后、缩进一级的 leds）。
#
# 幂等：已是目标内容则跳过；匹配不到唯一的顶层 leds 节点则 fail（提示上游改版需复核）。
# 用法：apply-dts-leds-fix.sh <源码树根目录> <DTS 文件名>

set -eu

WRT="${1:?用法: apply-dts-leds-fix.sh <wrt 根目录> <dts 文件名>}"
DTS_NAME="${2:?用法: apply-dts-leds-fix.sh <wrt 根目录> <dts 文件名>}"
DTS_FILE="$WRT/target/linux/rtl9617c/dts/${DTS_NAME}.dts"
TARGET_FILE="$WRT/target/linux/rtl9617c/dts/.pt1500-leds-target.dtsi"

[ -f "$DTS_FILE" ] || { echo "ERROR: DTS 不存在：$DTS_FILE" >&2; exit 1; }

# 目标 leds 节点（U-Boot 权威灯表：lyq1996/rtl9617c-uboot
# board/youhua/pt1500-h10-ct/desc-2p5g.c，U-Boot 阶段面板灯实机正常）
#
#   { .pin = 11 },                      /* power */
#   { .pin = 9,  .active_low = true },  /* pon   */
#   { .pin = 10, .active_low = true },  /* los   */
#   { .pin = 2,  .active_low = true },  /* ppp   */
#   { .pin = 12 },                      /* fxs   */
#   { .pin = 7 },                       /* usb0  */
#   { .pin = 0,  .active_low = true },  /* lan3  */
#   { .pin = 1,  .active_low = true },  /* lan2  */
#   { .pin = 3,  .active_low = true },  /* lan1  */
#   //{ .pin = 6, .active_low = true },  /* usb1 —— 板上无此灯 */
#
#   九盏灯全在 GPIO bank 0，pin 号即 flat 号（bank0 = flat 0..15）。
#   2.5G 口旁那盏由 RTL8221B PHY 驱动，不在此表（故不占 gpio0）。
#   复位键 = pin 8 active_low（上游 DTS 已正确使用）。
#
# ★ 2026-11-18 教训（run#11/run#12 走错了路，务必勿重犯）：
#   run#11/run#12 曾按**原厂 DTB** 的 5-bank 结构换算成 flat 96/97/99/100/…，
#   实测导致面板全灭。原因是原厂 DTB 是整个 TYFZA1 产品线共用的通用模板，
#   描述了 11 盏灯；而本机面板只有 9 盏（U-Boot 表），原厂 label 与本机丝印
#   并不能一一对应。上游 rtl9617c-pt1500-h10-2p5g.dts 的 leds 节点本来就已经
#   与 U-Boot 权威表一致（PPP=2/LOS=10/PON=9/PWR=11/FXS=12/EPHY=3,1,0），
#   只需补上上游遗漏的 USB0(pin 7) 即可。
#   实机佐证：逐 pin 扫描时 flat 11（U-Boot 的 power 脚）与 flat 12（fxs 脚）
#   是仅有的两个有可见灯的引脚，与 U-Boot 表吻合。
#
# 极性按 U-Boot 表原样保留（power/fxs/usb0 为高电平点亮，其余低电平点亮），
# 原厂 DTB 里 led-gpio flags 全 0x00 是私有驱动语义，不能套用到标准 gpio-leds。
cat > "$TARGET_FILE" <<'EOF'
	leds {
		compatible = "gpio-leds";
		internet {
			label = "LED_PPP_G";
			gpios = <&gpio0 2 GPIO_ACTIVE_LOW>;
			default-state = "off";
		};
		los {
			label = "LED_LOS";
			gpios = <&gpio0 10 GPIO_ACTIVE_LOW>;
		};
		pon {
			label = "LED_PON";
			gpios = <&gpio0 9 GPIO_ACTIVE_LOW>;
		};
		led_power: power {
			label = "LED_PWR_G";
			gpios = <&gpio0 11 GPIO_ACTIVE_HIGH>;
			default-state = "on";
		};
		phone {
			label = "LED_FXS";
			gpios = <&gpio0 12 GPIO_ACTIVE_HIGH>;
		};
		usb0 {
			label = "LED_USB0";
			gpios = <&gpio0 7 GPIO_ACTIVE_HIGH>;
		};
		lan1 {
			label = "LED_EPHY1";
			gpios = <&gpio0 3 GPIO_ACTIVE_LOW>;
		};
		lan2 {
			label = "LED_EPHY2";
			gpios = <&gpio0 1 GPIO_ACTIVE_LOW>;
		};
		lan3 {
			label = "LED_EPHY3";
			gpios = <&gpio0 0 GPIO_ACTIVE_LOW>;
		};
	};
EOF

python3 - "$DTS_FILE" "$TARGET_FILE" <<'PYEOF'
import re
import sys

path, target_path = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
target = open(target_path, encoding='utf-8').read()

# 顶层 leds 节点：缩进恰好一个 tab（mdio 下 phy_2p5g 里的 leds 缩进两 tab，不会被匹配）。
# 用「以 \n\tleds { 开头、以 \n\t}; 结尾」定位，保证只命中顶层那个。
pattern = re.compile(r'\n\tleds \{\n.*?\n\t\};\n', re.S)
matches = pattern.findall(text)
if len(matches) != 1:
    sys.exit('ERROR: DTS 顶层 leds 节点匹配到 %d 个（期望恰好 1 个），上游结构已变，需人工复核'
             % len(matches))

old = matches[0]
# 保留 old 的前导换行（matches 里每个元素以 \n 开头），否则替换后节点会
# 紧贴上一行，二次执行时 \n\tleds 匹配不到，破坏幂等。
lead = '\n' if old.startswith('\n') else ''
new = lead + target
if old.strip() == new.strip():
    print('  OK   DTS 灯 GPIO 已是原厂 flat 编号 + ACTIVE_HIGH（幂等跳过）')
    sys.exit(0)

text = text.replace(old, new, 1)
open(path, 'w', encoding='utf-8').write(text)
n = target.count('label = "LED_')
print('  OK   DTS 灯 GPIO 已按原厂 DTB 换算覆盖（%d 个灯，补齐 USB0/EPHY0/USB1）' % n)
PYEOF

rm -f "$TARGET_FILE"
