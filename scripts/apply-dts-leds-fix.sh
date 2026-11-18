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
# ★ 2026-11-18 方案 B：上游 /aliases 里有 4 行 led-* = &led_power，
#   而探测版 leds 节点不再定义 led_power label，dtc 的 path_references
#   会报 "Reference to non-existent node or label \"led_power\"" 并中止编译。
#   按用户选择执行方案 B：只删这 4 行别名引用，不补 label；
#   27 个 PROBE_<pin> 探测灯照常注册，供实机跑马灯确定真实引脚。
#
# 用法：apply-dts-leds-fix.sh <源码树根目录> <DTS 文件名>

set -eu

WRT="${1:?用法: apply-dts-leds-fix.sh <wrt 根目录> <dts 文件名>}"
DTS_NAME="${2:?用法: apply-dts-leds-fix.sh <wrt 根目录> <dts 文件名>}"
DTS_FILE="$WRT/target/linux/rtl9617c/dts/${DTS_NAME}.dts"
TARGET_FILE="$WRT/target/linux/rtl9617c/dts/.pt1500-leds-target.dtsi"

[ -f "$DTS_FILE" ] || { echo "ERROR: DTS 不存在：$DTS_FILE" >&2; exit 1; }

# 目标 leds 节点 —— **探测版**（2026-11-18）
#
# 背景：run#11/run#12 先后试过两种换算，结果都不对：
#   (a) 按原厂 DTB 的 5-bank 结构换算 -> flat 96/97/99/... 面板全灭；
#   (b) 按 U-Boot 灯表 (desc-2p5g.c, power=11/fxs=12/...) -> 与实机定点扫描
#       仍对不上（实机实测 flat 12 = 物理电源灯位、flat 96 = 物理电话灯位，
#       而 U-Boot 说 power=11、fxs=12）。
# 原厂 DTB 是整个 TYFZA1 产品线共用的通用模板（11 盏灯），label 与本机丝印
# 不能一一对应；U-Boot 的 pin 编号与 refactor 的 flat 编号同样不是恒等关系。
#
# 既然静态推导不可靠，改为**实测一次定死**：把候选引脚各注册成一颗独立 LED
# （label = PROBE_<pin>），刷上后跑一次跑马灯（每颗 3 秒，约 81 秒一轮），
# 肉眼记录哪几个位置亮了，即得到面板各盏灯的真实 flat 编号；探测完再收敛
# 成最终配置。
#
# 候选集 = bank0 的 0..14（跳过 15）+ bank3 的 96..108，共 27 个。
# 排除：flat 8（gpio-keys-polled 复位键）与 flat 15（USB tx-disable）——
# 这两个会被别的驱动 gpio_request，一旦冲突会让**整个 leds 节点 probe 失败**，
# 所有探测灯一颗都注册不出来。

cat > "$TARGET_FILE" <<'EOF'
	leds {
		compatible = "gpio-leds";
		probe0: p0 {
			label = "PROBE_0";
			gpios = <&gpio0 0 GPIO_ACTIVE_HIGH>;
		};
		probe1: p1 {
			label = "PROBE_1";
			gpios = <&gpio0 1 GPIO_ACTIVE_HIGH>;
		};
		probe2: p2 {
			label = "PROBE_2";
			gpios = <&gpio0 2 GPIO_ACTIVE_HIGH>;
		};
		probe3: p3 {
			label = "PROBE_3";
			gpios = <&gpio0 3 GPIO_ACTIVE_HIGH>;
		};
		probe4: p4 {
			label = "PROBE_4";
			gpios = <&gpio0 4 GPIO_ACTIVE_HIGH>;
		};
		probe5: p5 {
			label = "PROBE_5";
			gpios = <&gpio0 5 GPIO_ACTIVE_HIGH>;
		};
		probe6: p6 {
			label = "PROBE_6";
			gpios = <&gpio0 6 GPIO_ACTIVE_HIGH>;
		};
		probe7: p7 {
			label = "PROBE_7";
			gpios = <&gpio0 7 GPIO_ACTIVE_HIGH>;
		};
		probe9: p9 {
			label = "PROBE_9";
			gpios = <&gpio0 9 GPIO_ACTIVE_HIGH>;
		};
		probe10: p10 {
			label = "PROBE_10";
			gpios = <&gpio0 10 GPIO_ACTIVE_HIGH>;
		};
		probe11: p11 {
			label = "PROBE_11";
			gpios = <&gpio0 11 GPIO_ACTIVE_HIGH>;
		};
		probe12: p12 {
			label = "PROBE_12";
			gpios = <&gpio0 12 GPIO_ACTIVE_HIGH>;
		};
		probe13: p13 {
			label = "PROBE_13";
			gpios = <&gpio0 13 GPIO_ACTIVE_HIGH>;
		};
		probe14: p14 {
			label = "PROBE_14";
			gpios = <&gpio0 14 GPIO_ACTIVE_HIGH>;
		};
		probe96: p96 {
			label = "PROBE_96";
			gpios = <&gpio0 96 GPIO_ACTIVE_HIGH>;
		};
		probe97: p97 {
			label = "PROBE_97";
			gpios = <&gpio0 97 GPIO_ACTIVE_HIGH>;
		};
		probe98: p98 {
			label = "PROBE_98";
			gpios = <&gpio0 98 GPIO_ACTIVE_HIGH>;
		};
		probe99: p99 {
			label = "PROBE_99";
			gpios = <&gpio0 99 GPIO_ACTIVE_HIGH>;
		};
		probe100: p100 {
			label = "PROBE_100";
			gpios = <&gpio0 100 GPIO_ACTIVE_HIGH>;
		};
		probe101: p101 {
			label = "PROBE_101";
			gpios = <&gpio0 101 GPIO_ACTIVE_HIGH>;
		};
		probe102: p102 {
			label = "PROBE_102";
			gpios = <&gpio0 102 GPIO_ACTIVE_HIGH>;
		};
		probe103: p103 {
			label = "PROBE_103";
			gpios = <&gpio0 103 GPIO_ACTIVE_HIGH>;
		};
		probe104: p104 {
			label = "PROBE_104";
			gpios = <&gpio0 104 GPIO_ACTIVE_HIGH>;
		};
		probe105: p105 {
			label = "PROBE_105";
			gpios = <&gpio0 105 GPIO_ACTIVE_HIGH>;
		};
		probe106: p106 {
			label = "PROBE_106";
			gpios = <&gpio0 106 GPIO_ACTIVE_HIGH>;
		};
		probe107: p107 {
			label = "PROBE_107";
			gpios = <&gpio0 107 GPIO_ACTIVE_HIGH>;
		};
		probe108: p108 {
			label = "PROBE_108";
			gpios = <&gpio0 108 GPIO_ACTIVE_HIGH>;
		};
	};
EOF

python3 - "$DTS_FILE" "$TARGET_FILE" <<'PYEOF'
import re
import sys

path, target_path = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
target = open(target_path, encoding='utf-8').read()

# 方案 B：删掉 /aliases 中 4 行指向 led_power 的别名。探测版 leds 节点
# 不含该 label，dtc 的 path_references 会报错并中止编译。只删引用，
# 不碰 serial0，也不影响 27 个 PROBE 灯注册。
alias_re = re.compile(
    r'^[ \t]*led-(?:boot|failsafe|running|upgrade)[ \t]*=[ \t]*&led_power;[ \t]*\n?',
    re.M)
text, nalias = alias_re.subn('', text)
if '&led_power' in text:
    sys.exit('ERROR: DTS 仍残留 &led_power 引用，需人工复核 aliases 节点')

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
changed = False
if old.strip() != new.strip():
    text = text.replace(old, new, 1)
    changed = True
if changed or nalias:
    open(path, 'w', encoding='utf-8').write(text)
if changed:
    n = target.count('label = "PROBE_')
    print('  OK   DTS 面板灯已切换为 %d 个 PROBE_<pin> 探测灯' % n)
else:
    print('  OK   DTS 探测灯配置已是目标内容（幂等跳过）')
if nalias:
    print('  OK   已按方案 B 删除 %d 行指向 led_power 的 /aliases 引用（消除 dtc path_references 错误）' % nalias)

PYEOF

rm -f "$TARGET_FILE"
