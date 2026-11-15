#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PT1570-H10-CU 编译期 P6 / 2.5G 模式选择。

在「Apply H10-CU board injection」之后、「Configure」之前运行，作用于
已经注入到 OpenWrt 编译树里的那份 DTS（不改仓库里的 assets 原件，
因此 verify-h10-cu-board.py 的 boot-safe 断言始终成立）。

背景（2026-11-15 实机 + 上游源码同步）：

* CU run3 能启动（灯正常、可登录），2.5G 口不 link。run3 -> run4 的
  DTS 唯一实质差异是 ni0 新增 7 项 reg / reg-names，其中 "p6-serdes"
  让 rtl9617c-xram.c 的 priv->p6_serdes 被 ioremap。于是
  rtl_engine_start() -> rtl_p6_bringup() 不再是开头直接 return，而是
  真的执行 phy_power_on(sgmii) -> 脉冲 QXGMII block reset(BIT31) ->
  写 0xf550d000 QX SerDes 窗口 -> 加载 p6_serdes_sgmii_2g5.txt ->
  for(1501 次 && !clock_ready) mdelay(10) 约 15s 忙等 ->
  phy_set_speed(2500) -> rtl_p6_mac_config()。CU 是 XGPON + 双 PCIe
  WiFi6，PON MAC 窗口 4f5500000~4f550bfff 与 QX SerDes 相邻，这套
  QX 复位在 PT1500-H10 上验证过、在 CU 上没有，run4 刷入后整机起不来。

* 锁定 ref 20b4cf4 的驱动自带 realtek,p6-bringup-off 逃生开关，
  rtl_p6_bringup() 与 rtl_p6_set_speed() 开头都检查它。仓库 DTS 默认
  带上该属性（boot-safe），回到 run3 已验证能启动的行为。

* 上游 lyq1996/rtl9617c-openwrt HEAD 13ebc89b 相对本锁定 ref 有
  31/104 个 commit 分叉，关键新项是：
    - f74dc1e59646 "program the P6 lane for 1G"：把 SerDes 初始化抽成
      rtl_p6_serdes_init()，并在 link 降到 1G 时重新加载
      p6_serdes_sgmii_1g.txt（锁定 ref 已有该表与 RTL_P6_MODE_SGMII_1G
      0x4cf6，但 rtl_p6_set_speed() 只改 MAC、不重载 lane —— 这正是
      2.5G 口接 1G 对端时不 link 的可疑点）。
    - 8c91b228b41d "release fitblk before sysupgrade"：fit_do_upgrade。
      CU 已有 zz-pt1570-sysupgrade.sh 做 fitblk 释放且带断言，不能动。
    - 13ebc89b59d0 "use built-in RTL8221B PHY patch data"：内建 patch。
      锁定 ref 用 rtl8221b-tyfza1.h，等效。
    - net: split ni and fe again：树结构重写，删除 tyfza1-*.dtsi，
      现有三机型 workflow 全基于旧树，不能直接切 source_ref。

模式（workflow input p6_mode）：

  bootsafe（默认）
      不做任何改动，只断言注入的 DTS 确实带 realtek,p6-bringup-off。
      保证 CU 能启动；2.5G 口回到 run3 的「暂不 link」。

  attempt1g（实验，单独编译一版、单独刷，可能仍起不来）
      1) 删除 realtek,p6-bringup-off，让 QX bringup 真跑起来；
      2) 把 RTL_P6_CLOCK_TRIES 从 1501(约 15s 忙等) 降到 30(约 300ms)，
         去掉 boot 阶段最可疑的长忙等；
      3) 把 rtl_p6_set_speed() 换成上游 1G lane 编程的等价实现（内联，
         只用锁定 ref 已有的 rtl_p6_read/apply/mode_word/ind_write/
         clock_ready），link 降到 1G 时重新加载 p6_serdes_sgmii_1g.txt。
      这是「尝试」修复，不承诺成功；刷之前请先确认 bootsafe 版可用。

所有替换都是精确文本替换并做唯一性断言，锚点变了会直接编译失败，
不会静默产生一个半 patched 的固件。
"""
import os
import pathlib
import re
import sys

MODE = os.environ.get('P6_MODE', 'bootsafe').strip() or 'bootsafe'
WRT = pathlib.Path(os.environ.get('WRT', ''))
ASSETS = pathlib.Path(os.environ.get('ASSETS', ''))
DTS_NAME = os.environ.get('DTS', '').strip() or 'rtl9617c-pt1570-h10-cu'

fails = []


def ok(cond, msg):
    print(('  OK   ' if cond else '  FAIL ') + msg)
    if not cond:
        fails.append(msg)
    return cond


def replace_once(text, old, new, label):
    n = text.count(old)
    if not ok(n == 1, '%s（锚点命中 %d 次，期望 1 次）' % (label, n)):
        return text
    return text.replace(old, new, 1)


def main():
    if not WRT.is_dir() or not ASSETS.is_dir():
        print('ERROR: WRT/ASSETS 环境变量未指向有效目录', file=sys.stderr)
        return 1

    dts = WRT / 'target/linux/rtl9617c/dts' / (DTS_NAME + '.dts')
    drv = (WRT / 'target/linux/rtl9617c/files-6.18/drivers/net/ethernet/'
           'realtek/rtl9617c-xram.c')
    print('=== CU P6 mode = %s ===' % MODE)
    ok(dts.is_file(), '注入后的 DTS 存在：%s' % dts.name)
    ok(drv.is_file(), '锁定 ref 驱动存在：%s' % drv.name)
    if fails:
        return 1

    t = dts.read_text(encoding='utf-8')
    ok(re.search(r'^\s*realtek,p6-bringup-off\s*;', t, re.M) is not None,
       'assets DTS 带 realtek,p6-bringup-off（boot-safe 基线）')
    ok('"p6-serdes"' in t and '0xf550d000' in t,
       'assets DTS 保留 p6-serdes 资源（2.5G 尝试要用）')

    if MODE == 'bootsafe':
        # 默认路径：一个字节都不改，只确认注入结果就是 boot-safe 版。
        ok(True, 'bootsafe：保留 realtek,p6-bringup-off，QX bringup 关闭')
        print('  NOTE 2.5G 口处于 run3 状态（暂不 link）；如需单独尝试，'
              '重编时把 p6_mode 选 attempt1g')
    elif MODE == 'attempt1g':
        # 1) 打开 QX bringup
        t2 = replace_once(
            t, '\trealtek,p6-bringup-off;\n', '',
            'DTS 删除 realtek,p6-bringup-off')
        ni0 = t2.split('&ni0 {', 1)[-1].split('\n};', 1)[0]
        ok(re.search(r'^\s*realtek,p6-bringup-off\s*;', ni0, re.M) is None,
           'ni0 节点内不再带 bringup-off 属性（注释里的说明文字不算）')
        dts.write_text(t2, encoding='utf-8')

        c = drv.read_text(encoding='utf-8')
        # 2) 15s 忙等 -> 300ms
        c = replace_once(
            c, '#define RTL_P6_CLOCK_TRIES\t1501',
            '#define RTL_P6_CLOCK_TRIES\t30\t/* CU attempt1g: 300ms, '
            'not the 15s boot stall */',
            '驱动 CLOCK_TRIES 1501 -> 30')
        # 3) 上游 f74dc1e5 的 1G lane 编程（内联等价版，只用本 ref 已有符号）
        old_fn = """/* A 1G peer needs the matching lane load; 2.5G keeps the sgmii_2g5 profile. */
static void rtl_p6_set_speed(struct rtl_xram *priv, unsigned int speed)
{
	/* p6-bringup-off must disable the whole P6 path, including the link
	 * callback. */
	if (of_property_read_bool(priv->netdev->dev.parent->of_node,
				  "realtek,p6-bringup-off"))
		return;
	if (!priv->p6_serdes)
		return;
	/*
	 * The MAC is already fully programmed by rtl_p6_bringup() and the
	 * XGE_MAC_CFG_COM / XGE_MISC_CONFIG words it leaves behind match the
	 * stock firmware (0x0000e018 / 0x300000ff). Re-running the 1G
	 * reprogramming on every link transition reset those words to
	 * 0x00000008 / 0x200000ff and the P6 MAC stopped accepting frames.
	 * Only a real speed change needs the lane reload.
	 */
	if (priv->sgmii_speed == speed)
		return;
	priv->sgmii_speed = speed;
	rtl_p6_mac_config(priv);
	/* rtl_p6_mac_config() is the 1G variant and leaves the MAC on the GMII
	 * interface; put the P6 XGE MAC back on the OEM's 10G/2.5G select. */
	rtl_p6_mac_iface_select(priv);
}
"""
        new_fn = """/* Backport of upstream f74dc1e59646 "program the P6 lane for 1G".
 * The locked ref has p6_serdes_sgmii_1g.txt and RTL_P6_MODE_SGMII_1G,
 * but rtl_p6_set_speed() only touched the MAC, so a 1G peer never got the
 * matching SerDes lane profile. Reload the lane on a real speed change.
 * Inlined here (instead of adding rtl_p6_serdes_init) so that only symbols
 * already present in this ref are used: rtl_p6_read/apply/mode_word/
 * ind_write/clock_ready. The analog SDS byte stays at this ref's measured
 * indirect address 0x405 (upstream moved it to 0x160).
 */
static void rtl_p6_set_speed(struct rtl_xram *priv, unsigned int speed)
{
	bool two_g5 = speed == SPEED_2500;
	struct rtl_p6_profile *profile = &priv->p6_profile[two_g5 ? 0 : 1];
	u32 word = two_g5 ? RTL_P6_MODE_SGMII_2G5 : RTL_P6_MODE_SGMII_1G;
	u32 iface = two_g5 ? 0x12 : 0x02;
	unsigned int i;
	u32 value;

	/* p6-bringup-off must disable the whole P6 path, including the link
	 * callback. (Injected DTS has this property removed for attempt1g.) */
	if (of_property_read_bool(priv->netdev->dev.parent->of_node,
				  "realtek,p6-bringup-off"))
		return;
	if (!priv->p6_serdes)
		return;
	if (priv->sgmii_speed == speed)
		return;
	priv->sgmii_speed = speed;

	/* QXGMII block reset pulse, then load the speed-matching lane table. */
	if (priv->qm.block_reset) {
		value = readl(priv->qm.block_reset);
		writel(value | BIT(31), priv->qm.block_reset);
		udelay(1);
		writel(readl(priv->qm.block_reset) & ~BIT(31),
		       priv->qm.block_reset);
	}
	writel(readl(priv->p6_serdes) | BIT(0), priv->p6_serdes);
	writel(readl(priv->p6_serdes + 0x4) | 0x1f, priv->p6_serdes + 0x4);
	mdelay(1);
	writel((readl(priv->p6_serdes + 0x4) & ~0x1fU) | iface,
	       priv->p6_serdes + 0x4);
	rtl_p6_mode_word(priv, word);
	rtl_p6_ind_write(priv, 0x405, 0x009f);
	if (rtl_p6_read(priv, profile) == 0)
		rtl_p6_apply(priv, profile);
	else
		dev_warn(priv->netdev->dev.parent, "serdes load %s failed\\n",
			 profile->path);
	writel(readl(priv->p6_serdes) & ~BIT(0), priv->p6_serdes);
	for (i = 0; i < RTL_P6_CLOCK_TRIES && !rtl_p6_clock_ready(priv); i++)
		mdelay(RTL_P6_CLOCK_STEP_MS);

	if (!two_g5 && priv->sgmii) {
		int sret = phy_set_speed(priv->sgmii, speed);

		if (sret)
			dev_warn(priv->netdev->dev.parent,
				 "P6: S3 lane %uM programming failed: %d\\n",
				 speed, sret);
	}
	rtl_p6_mac_config(priv);
	rtl_p6_mac_iface_select(priv);
}
"""
        c2 = replace_once(c, old_fn, new_fn, '驱动 rtl_p6_set_speed 换成 1G lane 版')
        ok('p6_serdes_sgmii_1g.txt' in c2,
           '驱动仍引用 p6_serdes_sgmii_1g.txt（1G profile 路径）')
        drv.write_text(c2, encoding='utf-8')

        # 1G 表必须真的在编译树里
        tbl = (WRT / 'target/linux/rtl9617c/base-files/etc/serdes' /
               'p6_serdes_sgmii_1g.txt')
        ok(tbl.is_file(), '上游 1G SerDes 表存在：%s' % tbl.name)
        print('  NOTE attempt1g 已打开 QX bringup + 1G lane 重载；'
              '这是实验版，刷前请确认 bootsafe 版可用')
    else:
        ok(False, '未知 p6_mode=%s（只允许 bootsafe / attempt1g）' % MODE)

    print('CU_P6_MODE_OK=%s mode=%s fails=%d' %
          ('True' if not fails else 'False', MODE, len(fails)))
    if fails:
        for m in fails:
            print('  !! ' + m)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
