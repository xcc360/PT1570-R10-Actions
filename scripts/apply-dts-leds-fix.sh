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
# 极性说明：原厂 led-gpio 的 flags 全为 0x00（ACTIVE_HIGH），但原厂用的是私有
# g3hgu-gpio-led 驱动，"0=亮/1=亮"的语义未必等同标准 gpio-leds。上游 DTS 把
# PPP/LOS/PON/EPHY 全写成 ACTIVE_LOW、PWR/FXS 写成 ACTIVE_HIGH，这种混合更像
# 是按"灯灭"的状态反推的。**本脚本只改编号、不改极性**，保留上游的极性分组，
# 避免一次引入两个变量；极性等实机确认哪个亮哪个灭之后再单独调整。
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

# 目标 leds 节点（按原厂 flat 编号；极性沿用上游分组）
cat > "$TARGET_FILE" <<'EOF'
	leds {
		compatible = "gpio-leds";
		internet {
			label = "LED_PPP_G";
			gpios = <&gpio0 96 GPIO_ACTIVE_LOW>;
			default-state = "off";
		};
		los {
			label = "LED_LOS";
			gpios = <&gpio0 11 GPIO_ACTIVE_LOW>;
		};
		pon {
			label = "LED_PON";
			gpios = <&gpio0 108 GPIO_ACTIVE_LOW>;
		};
		led_power: power {
			label = "LED_PWR_G";
			gpios = <&gpio0 6 GPIO_ACTIVE_HIGH>;
			default-state = "on";
		};
		phone {
			label = "LED_FXS";
			gpios = <&gpio0 12 GPIO_ACTIVE_HIGH>;
		};
		lan1 {
			label = "LED_EPHY1";
			gpios = <&gpio0 103 GPIO_ACTIVE_LOW>;
		};
		lan2 {
			label = "LED_EPHY2";
			gpios = <&gpio0 97 GPIO_ACTIVE_LOW>;
		};
		lan3 {
			label = "LED_EPHY3";
			gpios = <&gpio0 100 GPIO_ACTIVE_LOW>;
		};
		usb0 {
			label = "LED_USB0";
			gpios = <&gpio0 99 GPIO_ACTIVE_LOW>;
		};
		ephy0 {
			label = "LED_EPHY0";
			gpios = <&gpio0 102 GPIO_ACTIVE_LOW>;
		};
		usb1 {
			label = "LED_USB1";
			gpios = <&gpio0 101 GPIO_ACTIVE_LOW>;
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
new = target
if old.strip() == new.strip():
    print('  OK   DTS 灯 GPIO 已是原厂 flat 编号（幂等跳过）')
    sys.exit(0)

text = text.replace(old, new, 1)
open(path, 'w', encoding='utf-8').write(text)
n = target.count('label = "LED_')
print('  OK   DTS 灯 GPIO 已按原厂 DTB 换算覆盖（%d 个灯，补齐 USB0/EPHY0/USB1）' % n)
PYEOF

rm -f "$TARGET_FILE"
