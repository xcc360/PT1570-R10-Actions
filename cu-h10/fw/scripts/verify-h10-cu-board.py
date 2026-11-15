#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PT1570-H10-CU 板级静态护栏：固件态 有线网口 + 面板灯 + 黑砖修复。

本地与 CI 共用（apply-board-h10-cu.sh / workflow preflight 都会调用）。
依据：
  * 联通原厂 mtd4 内嵌 DTB 的 rtk_gpio_led 节点（低号 GPIO / 极性）
  * 2026-11-15 实机确认的 U-Boot run#5 灯表
  * 第二版 sysupgrade 实测：电源灯不亮、网口灯错位、只有网口2/3可用
  * rtl9617c-xram 驱动 rtl_register_lans() 的 lan-phys / p6-phy 语义
"""
import pathlib
import re
import subprocess
import sys

FW = pathlib.Path(__file__).resolve().parents[1]          # cu-h10/fw
DTS = FW / 'board/dts/rtl9617c-pt1570-h10-cu.dts'
UCI = FW / 'files-cu/etc/uci-defaults'
LAN = UCI / '96-pt1570-h10-cu-lan5'
LEDS = UCI / '98-pt1570-h10-cu-leds'

fails = []
checks = 0


def ok(cond, msg):
    global checks
    checks += 1
    print(('  OK   ' if cond else '  FAIL ') + msg)
    if not cond:
        fails.append(msg)
    return cond


def main():
    if not DTS.is_file():
        print('ERROR: 找不到 CU DTS: %s' % DTS)
        return 1
    t = DTS.read_text(encoding='utf-8')

    print('=== 1. 2p5g 基线 / 统一 UBI / 黑砖修复 ===')
    ok(re.search(r'^#include\s+"rtl9617c-tyfza1-2p5g\.dts"', t, re.M) is not None,
       'include 2p5g 板定义（外置 2.5G PHY 基线）')
    ok(re.search(r'^#include\s+"rtl9617c-tyfza1-4ge\.dts"', t, re.M) is None,
       '未误用 4GE 空壳板定义')
    ok('/delete-property/ read-only' in t and 'partition@340000' in t,
       'ubi_device 分区可写（否则刷入态只读 UBI -> overlay 建不出 -> 黑砖）')
    ok('UNVERIFIED' not in t, 'DTS 无 UNVERIFIED 标记')

    print('=== 2. 固件态面板灯：联通原厂低号 GPIO ===')
    # 面板左→右顺序，GPIO 与极性逐脚来自原厂 rtk_gpio_led 节点
    leds = [
        ('internet', 2, 'LOW'),   # 宽带 LED_PPP_G
        ('los',     10, 'LOW'),   # 光信号 LED_LOS
        ('pon',      9, 'LOW'),   # 注册 LED_PON
        ('power',   11, 'HIGH'),  # 电源 LED_PWR_G
        ('phone',   12, 'HIGH'),  # 电话 LED_FXS
        ('lan0',     4, 'LOW'),   # 2.5G口 LED_EPHY0（PHY-wired，长灭）
        ('lan1',     3, 'LOW'),   # 千兆口2 LED_EPHY1
        ('lan2',     1, 'LOW'),   # 千兆口3 LED_EPHY2
        ('lan3',     0, 'LOW'),   # 千兆口4 LED_EPHY3
        ('usb0',     7, 'HIGH'),  # USB LED_USB0（2p5g 删掉，CU 重建）
        ('usb1',     6, 'LOW'),   # LED_USB1
        ('wps',      5, 'HIGH'),  # WPS LED_WPS_G
    ]
    for name, pin, pol in leds:
        m = re.search(r'\b' + name + r'\s*\{[^}]*?gpios\s*=\s*<&gpio0\s+(\d+)\s+GPIO_ACTIVE_(LOW|HIGH)>',
                      t, re.S)
        ok(m is not None and int(m.group(1)) == pin and m.group(2) == pol,
           'LED %-9s -> gpio0 %-3d active %s' % (name, pin, pol))
    ok(re.search(r'power\s*\{[^}]*?default-state\s*=\s*"on"', t, re.S) is not None,
       '电源灯 default-state = on（否则刷入后电源灯始终不亮）')
    for bad in (70, 71, 139, 140):
        ok(re.search(r'&gpio0\s+%d\b' % bad, t) is None,
           '无电信 2p5g 高号 GPIO %d 残留（灯错位的根因）' % bad)

    print('=== 3. 2.5G / 四个 GE 网口 ===')
    ok(re.search(r'phy_2p5g:\s*ethernet-phy@6\s*\{', t) is not None,
       '2.5G PHY 定义在 MDIO addr 6（原厂 ext_gphy port_mapping_phyAddr=<6 6>）')
    m6 = re.search(r'phy_2p5g:\s*ethernet-phy@6\s*\{([^}]*)\}', t, re.S)
    if m6:
        b = m6.group(1)
        ok(re.search(r'reg\s*=\s*<6>', b) is not None, 'phy@6 reg = <6>')
        for prop in ('realtek,hsgmii', 'realtek,no-vendor-finish',
                     'realtek,oem-sds-option'):
            ok(prop in b, 'phy@6 带 ' + prop)
        ok('ethernet-phy-ieee802.3-c45' not in b,
           'phy@6 保持 Clause 22（C45 会让 HiSGMII 初始化打死铜线 link）')
    else:
        ok(False, 'phy@6 节点可解析')
    ok(re.search(r'ethernet-phy@7\s*\{[^}]*?status\s*=\s*"disabled"', t, re.S) is not None,
       '电信 C45 addr7 节点已禁用（消除 "MDIO device at address 7 is missing"）')
    m = re.search(r'realtek,lan-phys\s*=\s*<([^>]*)>', t)
    ok(m is not None and m.group(1).strip() == '&phy0 &phy1 &phy2 &phy3',
       'lan-phys 四个真实 GE PHY 占满 index 0..3（port3 不再空 -> lan4 注册）')
    ok(m is None or '&phy4' not in m.group(1),
       'lan-phys 不再引用不存在的 &phy4（消除 LAN4 initialization failed: -19）')
    ok(re.search(r'realtek,p6-phy\s*=\s*<&phy_2p5g>', t) is not None,
       'realtek,p6-phy 指向 phy_2p5g（否则 P6 2.5G 口 netdev lan1 不注册）')
    ok(re.search(r'phys\s*=\s*<&pcie_controls\s+5>', t) is not None,
       'SGMII lane phys = <&pcie_controls 5>')

    print('=== 3b. P6 SerDes 资源 + boot-safe 逃生开关（2026-11-15 run4 砖版回退）===')
    # 资产完整性仍锁死：7 项 reg / reg-names 不能回退，2.5G 后续尝试要用。
    ok('"p6-serdes"' in t, 'ni0 reg-names 含 "p6-serdes" 资源名')
    ok('0xf550d000' in t, 'P6 QX SerDes 寄存器窗 0xf550d000 已声明')
    ok('realtek,dma-tx' in t, 'ni0 带 realtek,dma-tx（多口板 PORT_TO_CPU 必需）')
    ok('realtek,qm-rx' in t, 'ni0 带 realtek,qm-rx（P6 共享 CPU0 QM 池）')
    # run3 -> run4 唯一实质差异就是放开 QX bringup，CU 刷入后整机起不来。
    # 锁定 ref 的 rtl9617c-xram.c 里 rtl_p6_bringup() / rtl_p6_set_speed()
    # 开头都检查 realtek,p6-bringup-off；带上它才回到 run3 已验证可启动的行为。
    # 这一条防的是「以后有人为了试 2.5G 把开关删掉又刷砖」。
    ok(re.search(r'^\s*realtek,p6-bringup-off\s*;', t, re.M) is not None,
       'ni0 带 realtek,p6-bringup-off（boot-safe：关掉 QX 复位/15s 等时钟，保证能启动）')
    ok(t.count('realtek,p6-bringup-off;') == 1,
       'realtek,p6-bringup-off 只出现一次（p6_attempt 由编译期脚本删除，不在仓库 DTS 里改）')

    print('=== 4. CU 专用首启脚本 ===')
    for f in (LAN, LEDS):
        ok(f.is_file(), '存在 %s' % f.name)
    if LAN.is_file():
        l = LAN.read_text(encoding='utf-8')
        for dev in ('lan1', 'lan2', 'lan3', 'lan4'):
            ok(dev in l, 'bridge 脚本覆盖 %s' % dev)
        ok('lan0' in l and 'lan5' in l,
           'bridge 脚本会剔除 phantom lan0 / 旧形态 lan5')
        ok('/sys/class/net/lan4' in l,
           'bridge 脚本等 lan4 就绪（不再死等不存在的 lan5）')
    if LEDS.is_file():
        s = LEDS.read_text(encoding='utf-8')
        ok('youhua,pt1570-h10-cu' in s, 'LED 脚本按 board_name 门控')
        ok('LED_PWR_G' in s, 'LED 脚本有电源灯兜底')
        ok('LED_USB0' in s, 'LED 脚本校正 USB 灯 sysfs')
    try:
        for f in (LAN, LEDS):
            if f.is_file():
                r = subprocess.run(['bash', '-n', str(f)], capture_output=True, text=True)
                ok(r.returncode == 0, 'bash -n %s' % f.name)
    except FileNotFoundError:
        print('  SKIP bash -n（本机无 bash）')

    print('=== 5. 三机型统一默认 LAN 192.168.1.1 ===')
    WAN = UCI / '95-pt1570-h10-cu-wan-default'
    CUSTOMIZE = FW / 'customize-cu.sh'
    ok(WAN.is_file(), '存在 95-pt1570-h10-cu-wan-default')
    if WAN.is_file():
        w = WAN.read_text(encoding='utf-8')
        ok("uci -q set network.lan.ipaddr='192.168.1.1/24'" in w,
           '首启脚本把默认/旧 LAN 地址统一到 192.168.1.1/24')
        ok('192.168.18.1/24' in w and '192.168.2.1/24' in w,
           '首启脚本仍会把旧默认值迁移过来（sysupgrade 保留配置）')
    ok(CUSTOMIZE.is_file()
       and 'WRT_IP="${WRT_IP:-192.168.1.1}"' in CUSTOMIZE.read_text(encoding='utf-8'),
       'customize-cu.sh 默认 IP = 192.168.1.1')

    print('=== 6. 开机 WiFi 诊断脚本（run3 仍无无线，需实机证据）===')
    ok((UCI / '97-pt1570-h10-cu-wifi-diag').is_file(),
       '存在 97-pt1570-h10-cu-wifi-diag')

    print('H10CU_BOARD_GUARD_OK=%s checks=%d fails=%d' %
          ('True' if not fails else 'False', checks, len(fails)))
    if fails:
        for m in fails:
            print('  !! ' + m)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
