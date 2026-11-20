// SPDX-License-Identifier: GPL-2.0-only
/* Native Taurus PCIe clock/reset/PHY providers. Register behavior from
 * GPL-for-GP3000 phy-rtk-taurus.c and this board's original device tree. */
#include <linux/clk-provider.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/mfd/syscon.h>
#include <linux/of.h>
#include <linux/phy/phy.h>
#include <linux/platform_device.h>
#include <linux/reset-controller.h>
#include <linux/regmap.h>
#include "../net/ethernet/realtek/rtl9617c-sgmii.h"

struct rtl_pcie_controls;
struct rtl_pcie_lane {
	struct rtl_pcie_controls *controls;
	unsigned int id;
};
struct rtl_pcie_controls {
	void __iomem *core_reset, *phy_reset, *phy_control, *power, *usb_reset;
	void __iomem *sgmii_analog, *sgmii_serdes;
	/* SGMII_LP block (0xf433a000); OEM reads its lane status at +0xf4. */
	void __iomem *sgmii_lp;
	/* Mapped lengths, used to bound the phy_win diagnostic window. */
	size_t phy_control_size, power_size, sgmii_analog_size;
	size_t sgmii_serdes_size, sgmii_lp_size;
	/* Last value touched through the phy_win diagnostic attribute. */
	u32 win_last;
	struct regmap *global_config;
	spinlock_t lock;
	u32 powered_lanes;
	struct reset_controller_dev reset;
	struct clk_hw_onecell_data *clocks;
	struct phy *phys[6];
	struct rtl_pcie_lane lanes[6];
};
struct rtl_pcie_gate {
	struct clk_hw hw;
	struct regmap *regmap;
	unsigned int bit;
};
static int rtl_pcie_gate_enable(struct clk_hw *hw)
{
	struct rtl_pcie_gate *gate = container_of(hw, struct rtl_pcie_gate, hw);

	return regmap_update_bits(gate->regmap, 0, BIT(gate->bit), BIT(gate->bit));
}
static void rtl_pcie_gate_disable(struct clk_hw *hw)
{
	struct rtl_pcie_gate *gate = container_of(hw, struct rtl_pcie_gate, hw);

	regmap_update_bits(gate->regmap, 0, BIT(gate->bit), 0);
}
static int rtl_pcie_gate_enabled(struct clk_hw *hw)
{
	struct rtl_pcie_gate *gate = container_of(hw, struct rtl_pcie_gate, hw);
	u32 value;
	int ret = regmap_read(gate->regmap, 0, &value);

	return ret ? ret : !!(value & BIT(gate->bit));
}
static const struct clk_ops rtl_pcie_gate_ops = {
	.enable = rtl_pcie_gate_enable,
	.disable = rtl_pcie_gate_disable,
	.is_enabled = rtl_pcie_gate_enabled,
};

static void rtl_pcie_update(struct rtl_pcie_controls *controls,
			    void __iomem *reg, u32 mask, u32 value)
{
	unsigned long flags;

	spin_lock_irqsave(&controls->lock, flags);
	writel((readl(reg) & ~mask) | value, reg);
	spin_unlock_irqrestore(&controls->lock, flags);
}
static int rtl_pcie_reset_set(struct reset_controller_dev *reset,
			      unsigned long id, bool asserted)
{
	struct rtl_pcie_controls *controls = container_of(reset, struct rtl_pcie_controls, reset);
	void __iomem *reg = id < 2 ? controls->core_reset : controls->phy_reset;
	u32 mask = BIT(id < 2 ? 6 + id : id - 2);

	if (id == 4) {
		reg = controls->core_reset;
		mask = BIT(13);
	} else if (id == 5) {
		reg = controls->usb_reset;
		mask = BIT(5);
	}

	rtl_pcie_update(controls, reg, mask, asserted ? mask : 0);
	return 0;
}
static int rtl_pcie_reset_assert(struct reset_controller_dev *reset, unsigned long id)
{
	return rtl_pcie_reset_set(reset, id, true);
}
static int rtl_pcie_reset_deassert(struct reset_controller_dev *reset, unsigned long id)
{
	return rtl_pcie_reset_set(reset, id, false);
}
static const struct reset_control_ops rtl_pcie_reset_ops = {
	.assert = rtl_pcie_reset_assert,
	.deassert = rtl_pcie_reset_deassert,
};

static int rtl_pcie_lane_power(struct phy *phy, bool enabled)
{
	struct rtl_pcie_lane *lane = phy_get_drvdata(phy);
	struct rtl_pcie_controls *controls = lane->controls;
	unsigned int id = lane->id;
	u32 supply = BIT(7 + id) | BIT(20 + id * 2) | BIT(21 + id * 2);
	u32 isolation = BIT(id);
	u32 analog = BIT(16 + id / 2), value;
	unsigned long flags;

	/* S0/S1 ISO_ANA_B belongs to both lanes, not to the lane0 consumer. */
	spin_lock_irqsave(&controls->lock, flags);
	if (id == 5) {
		value = readl(controls->phy_control);
		if (enabled)
			value = (value | BIT(25)) & ~BIT(26);
		writel(value, controls->phy_control);
		value = readl(controls->power);
		value = enabled ? (value | 0xc0080000) & ~0x6020 :
			(value & ~0xc0080000) | 0x6020;
		writel(value, controls->power);
		if (enabled) {
			writel(0x5359, controls->sgmii_serdes + 0x1c);
			writel(0x30, controls->phy_control + 0x0c);
			writel(0x34200248, controls->phy_control + 0x10);
		}
		spin_unlock_irqrestore(&controls->lock, flags);
		return 0;
	}
	/* Stock PHY5 is the USB S2 lane. Share the PCIe register lock so
	 * USB initialization cannot overwrite another lane's power bits. */
	if (id == 4) {
		value = readl(controls->phy_control);
		if (enabled)
			value = (value | 0x00180000) & ~0x00600000;
		writel(value, controls->phy_control);
		value = readl(controls->power);
		value = enabled ? (value | 0x30040800) & ~0x1010 :
			(value & ~0x30040800) | 0x1010;
		writel(value, controls->power);
		spin_unlock_irqrestore(&controls->lock, flags);
		return 0;
	}
	if (enabled) {
		controls->powered_lanes |= BIT(id);
		if (id < 2)
			writel(readl(controls->phy_control) & ~BIT(27), controls->phy_control);
	} else {
		controls->powered_lanes &= ~BIT(id);
	}
	value = readl(controls->power) & ~(supply | isolation | analog);
	value |= enabled ? supply : isolation;
	if (controls->powered_lanes & (3U << (id & ~1U)))
		value |= analog;
	writel(value, controls->power);
	spin_unlock_irqrestore(&controls->lock, flags);
	return 0;
}
static int rtl_pcie_lane_on(struct phy *phy)
{
	return rtl_pcie_lane_power(phy, true);
}
static int rtl_pcie_lane_off(struct phy *phy)
{
	return rtl_pcie_lane_power(phy, false);
}
static int rtl_pcie_lane_speed(struct phy *phy, int speed)
{
	struct rtl_pcie_lane *lane = phy_get_drvdata(phy);
	struct rtl_pcie_controls *controls = lane->controls;
	unsigned long flags;

	if (lane->id != 5 || (speed != 10 && speed != 100 && speed != 1000 && speed != 2500))
		return -EINVAL;
	spin_lock_irqsave(&controls->lock, flags);
	rtl_sgmii_link(controls->phy_control, controls->phy_reset,
		controls->phy_control + 0x10, controls->sgmii_analog, speed);
	spin_unlock_irqrestore(&controls->lock, flags);
	/* Bring-up visibility: the analog bank and the SGMII PCS must both end
	 * up programmed for the requested speed. b404/b428 are written by the
	 * stock __p4_sds_2g5_patch(), d4 holds the SGMII PCS control word. */
	pr_info("S3 speed %d: ctrl=%08x reset=%08x pcs=%08x ana404=%08x ana428=%08x status=%08x misc=%08x\n",
		speed, readl(controls->phy_control), readl(controls->phy_reset),
		readl(controls->phy_control + 0x10),
		readl(controls->sgmii_analog + 0x404),
		readl(controls->sgmii_analog + 0x428),
		readl(controls->phy_control + 0x08),
		readl(controls->phy_control + 0x0c));
	/* The PLL may need a little time; the first read is taken right after
	 * the PCS write. Read it again once the lane has had time to lock. */
	mdelay(100);
	pr_info("S3 settle: status=%08x misc=%08x pcs_info=%08x\n",
		readl(controls->phy_control + 0x08),
		readl(controls->phy_control + 0x0c),
		readl(controls->phy_control + 0x1c));
	return 0;
}
static const struct phy_ops rtl_pcie_phy_ops = {
	.power_on = rtl_pcie_lane_on,
	.power_off = rtl_pcie_lane_off,
	.set_speed = rtl_pcie_lane_speed,
	.owner = THIS_MODULE,
};
static struct phy *rtl_pcie_phy_xlate(struct device *dev, const struct of_phandle_args *args)
{
	struct rtl_pcie_controls *controls = dev_get_drvdata(dev);

	if (args->args_count != 1 || args->args[0] >= ARRAY_SIZE(controls->phys))
		return ERR_PTR(-EINVAL);
	return controls->phys[args->args[0]];
}
static ssize_t sgmii_status_show(struct device *dev,
				 struct device_attribute *attr, char *buf);
static DEVICE_ATTR_RO(sgmii_status);

/* Raw GLOBAL_PHY_SGMII_MISC_CONTROL access, for bringing the S3 lane's
 * clock buffer / bandgap up while the lane is being diagnosed. */
static ssize_t sgmii_misc_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	struct rtl_pcie_controls *controls = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%08x\n", readl(controls->phy_control + 0x0c));
}

static ssize_t sgmii_misc_store(struct device *dev,
				struct device_attribute *attr,
				const char *buf, size_t count)
{
	struct rtl_pcie_controls *controls = dev_get_drvdata(dev);
	unsigned long flags;
	unsigned int value;
	int ret = kstrtouint(buf, 0, &value);

	if (ret)
		return ret;
	/* Same register the lane bring-up rewrites; serialize with it. */
	spin_lock_irqsave(&controls->lock, flags);
	writel(value, controls->phy_control + 0x0c);
	spin_unlock_irqrestore(&controls->lock, flags);
	return count;
}
static DEVICE_ATTR_RW(sgmii_misc);

/*
 * GLOBAL_PHY_ISO_POWER_CTRL (the "power" resource). The S3 lane that carries
 * the 2.5G SGMII PHY has s3_CPHY_ISOLATE (bit 5) and s3_ISO_ANA_B (bit 19);
 * while either isolates the analog block the lane cannot transmit or receive,
 * which is exactly the symptom seen on the 2.5G jack. Expose the raw word so
 * the isolation state can be read and cleared from userspace.
 */
static ssize_t phy_power_show(struct device *dev,
			      struct device_attribute *attr, char *buf)
{
	struct rtl_pcie_controls *controls = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%08x\n", readl(controls->power));
}

static ssize_t phy_power_store(struct device *dev,
			       struct device_attribute *attr,
			       const char *buf, size_t count)
{
	struct rtl_pcie_controls *controls = dev_get_drvdata(dev);
	unsigned long flags;
	unsigned int value;
	int ret = kstrtouint(buf, 0, &value);

	if (ret)
		return ret;
	/* Share the lane lock: this register also holds every lane's power and
	 * isolation bits, so an unlocked write races rtl_pcie_lane_power(). */
	spin_lock_irqsave(&controls->lock, flags);
	writel(value, controls->power);
	spin_unlock_irqrestore(&controls->lock, flags);
	return count;
}
static DEVICE_ATTR_RW(phy_power);

/*
 * Generic word access to every mapped block, for bring-up work:
 *
 *   echo "<block> <offset> [value]" > phy_win
 *
 * Block names are the DT reg-names. A read stores the value, which is
 * printed by reading the file. This exists so a candidate register can be
 * inspected from the device without a rebuild each time; it is a diagnostic
 * aid, not part of normal operation.
 *
 * Offsets are bounded per block by that block's mapped length: the resources
 * are not all 4 KiB (power is 4 bytes, phy-control 0x20), so a single
 * "offset < 0x1000" test would let a mistyped command read or write past the
 * ioremap and fault the bus.
 */
struct rtl_win_block {
	const char *name;
	size_t size;
};

static void __iomem *rtl_win_block(struct rtl_pcie_controls *controls,
				   const char *name, size_t *size)
{
	if (!strcmp(name, "phy-control")) {
		*size = controls->phy_control_size;
		return controls->phy_control;
	}
	if (!strcmp(name, "power")) {
		*size = controls->power_size;
		return controls->power;
	}
	if (!strcmp(name, "sgmii-analog")) {
		*size = controls->sgmii_analog_size;
		return controls->sgmii_analog;
	}
	if (!strcmp(name, "sgmii-serdes")) {
		*size = controls->sgmii_serdes_size;
		return controls->sgmii_serdes;
	}
	if (!strcmp(name, "sgmii-lp")) {
		*size = controls->sgmii_lp_size;
		return controls->sgmii_lp;
	}
	return NULL;
}

static ssize_t phy_win_show(struct device *dev, struct device_attribute *attr,
			    char *buf)
{
	struct rtl_pcie_controls *controls = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%08x\n", controls->win_last);
}

static ssize_t phy_win_store(struct device *dev, struct device_attribute *attr,
			     const char *buf, size_t count)
{
	struct rtl_pcie_controls *controls = dev_get_drvdata(dev);
	unsigned long flags;
	char name[32] = "";
	unsigned int off = 0, val = 0;
	size_t size = 0;
	void __iomem *blk;
	int n;

	n = sscanf(buf, "%31s %x %x", name, &off, &val);
	if (n < 2 || (off & 3))
		return -EINVAL;
	blk = rtl_win_block(controls, name, &size);
	if (!blk)
		return -ENODEV;
	/* Bound against this block's own length, not a blanket 0x1000. */
	if ((size_t)off + sizeof(u32) > size)
		return -EINVAL;
	spin_lock_irqsave(&controls->lock, flags);
	if (n >= 3)
		writel(val, blk + off);
	controls->win_last = readl(blk + off);
	spin_unlock_irqrestore(&controls->lock, flags);
	return count;
}
static DEVICE_ATTR_RW(phy_win);

static int rtl_pcie_controls_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct rtl_pcie_controls *controls;
	struct phy_provider *provider;
	unsigned int i;
	int ret;

	controls = devm_kzalloc(dev, sizeof(*controls), GFP_KERNEL);
	if (!controls)
		return -ENOMEM;
	controls->core_reset = devm_platform_ioremap_resource_byname(pdev, "core-reset");
	if (IS_ERR(controls->core_reset))
		return PTR_ERR(controls->core_reset);
	controls->phy_reset = devm_platform_ioremap_resource_byname(pdev, "phy-reset");
	if (IS_ERR(controls->phy_reset))
		return PTR_ERR(controls->phy_reset);
	controls->usb_reset = devm_platform_ioremap_resource_byname(pdev, "usb-reset");
	if (IS_ERR(controls->usb_reset))
		return PTR_ERR(controls->usb_reset);
	controls->global_config = syscon_regmap_lookup_by_phandle(dev->of_node, "realtek,global-config");
	if (IS_ERR(controls->global_config))
		return PTR_ERR(controls->global_config);
	controls->phy_control = devm_platform_ioremap_resource_byname(pdev, "phy-control");
	if (IS_ERR(controls->phy_control))
		return PTR_ERR(controls->phy_control);
	controls->power = devm_platform_ioremap_resource_byname(pdev, "power");
	if (IS_ERR(controls->power))
		return PTR_ERR(controls->power);
	controls->sgmii_analog = devm_platform_ioremap_resource_byname(pdev, "sgmii-analog");
	if (IS_ERR(controls->sgmii_analog))
		return PTR_ERR(controls->sgmii_analog);
	/*
	 * SGMII_LP (0xf433a000) is a different block from SGMII_HP
	 * (0xf433b000, mapped as sgmii-analog). OEM ca-ne.ko takes the lane
	 * link status from SGMII_LP + 0xf4 (__p4_sds_status_get,
	 * ca-ne.ko+0x1b080), so map it too; optional so older trees boot.
	 */
	controls->sgmii_lp = devm_platform_ioremap_resource_byname(pdev, "sgmii-lp");
	if (IS_ERR(controls->sgmii_lp))
		controls->sgmii_lp = NULL;
	controls->sgmii_serdes = devm_platform_ioremap_resource_byname(pdev, "sgmii-serdes");
	if (IS_ERR(controls->sgmii_serdes))
		return PTR_ERR(controls->sgmii_serdes);
	/* Record each block's mapped length for the phy_win bounds check. */
	controls->phy_control_size =
		resource_size(platform_get_resource_byname(pdev, IORESOURCE_MEM, "phy-control"));
	controls->power_size =
		resource_size(platform_get_resource_byname(pdev, IORESOURCE_MEM, "power"));
	controls->sgmii_analog_size =
		resource_size(platform_get_resource_byname(pdev, IORESOURCE_MEM, "sgmii-analog"));
	controls->sgmii_serdes_size =
		resource_size(platform_get_resource_byname(pdev, IORESOURCE_MEM, "sgmii-serdes"));
	controls->sgmii_lp_size = controls->sgmii_lp ?
		resource_size(platform_get_resource_byname(pdev, IORESOURCE_MEM, "sgmii-lp")) : 0;
	spin_lock_init(&controls->lock);
	platform_set_drvdata(pdev, controls);
	controls->clocks = devm_kzalloc(dev, struct_size(controls->clocks, hws, 2), GFP_KERNEL);
	if (!controls->clocks)
		return -ENOMEM;
	controls->clocks->num = 2;
	for (i = 0; i < 2; i++) {
		const char *name = devm_kasprintf(dev, GFP_KERNEL, "rtl9617c-pcie%u", i);
		struct clk_init_data init = {.name = name, .ops = &rtl_pcie_gate_ops};
		struct rtl_pcie_gate *gate;

		if (!name)
			return -ENOMEM;
		gate = devm_kzalloc(dev, sizeof(*gate), GFP_KERNEL);
		if (!gate)
			return -ENOMEM;
		gate->regmap = controls->global_config;
		gate->bit = 10 + i * 2;
		gate->hw.init = &init;
		ret = devm_clk_hw_register(dev, &gate->hw);
		if (ret)
			return ret;
		controls->clocks->hws[i] = &gate->hw;
	}
	ret = devm_of_clk_add_hw_provider(dev, of_clk_hw_onecell_get, controls->clocks);
	if (ret)
		return ret;
	controls->reset.owner = THIS_MODULE;
	controls->reset.ops = &rtl_pcie_reset_ops;
	controls->reset.of_node = dev->of_node;
	controls->reset.nr_resets = 6; /* PCIe core/DPHY pairs, USB core/USB2 port1 */
	ret = devm_reset_controller_register(dev, &controls->reset);
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(controls->phys); i++) {
		controls->lanes[i] = (struct rtl_pcie_lane){.controls = controls, .id = i};
		controls->phys[i] = devm_phy_create(dev, NULL, &rtl_pcie_phy_ops);
		if (IS_ERR(controls->phys[i]))
			return PTR_ERR(controls->phys[i]);
		phy_set_drvdata(controls->phys[i], &controls->lanes[i]);
	}
	provider = devm_of_phy_provider_register(dev, rtl_pcie_phy_xlate);
	if (IS_ERR(provider))
		return PTR_ERR(provider);
	/* Diagnostics for the SGMII lane that carries the 2.5G jack. */
	ret = device_create_file(dev, &dev_attr_sgmii_status);
	if (ret)
		dev_warn(dev, "sgmii_status attribute not created: %d\n", ret);
	ret = device_create_file(dev, &dev_attr_sgmii_misc);
	if (ret)
		dev_warn(dev, "sgmii_misc attribute not created: %d\n", ret);
	ret = device_create_file(dev, &dev_attr_phy_power);
	if (ret)
		dev_warn(dev, "phy_power attribute not created: %d\n", ret);
	ret = device_create_file(dev, &dev_attr_phy_win);
	if (ret)
		dev_warn(dev, "phy_win attribute not created: %d\n", ret);
	return 0;
}

/*
 * SGMII lane diagnostics. GLOBAL_PHY_STATUS (phy_control + 0x08) carries the
 * per-lane CKUSABLE bits and GLOBAL_PHY_SGMII_PCS_INFO (phy_control + 0x1c)
 * carries sgmii_sds_link_ok (bit0), reg_rdy (bit1) and the 17-bit partner
 * ability. Without these there is no way to tell whether the lane is
 * receiving, which is the difference between "no frames because the copper
 * side is idle" and "no frames because the lane never locked".
 */
static ssize_t sgmii_status_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct rtl_pcie_controls *controls = dev_get_drvdata(dev);
	u32 status = readl(controls->phy_control + 0x08);
	u32 info = readl(controls->phy_control + 0x1c);
	u32 misc = readl(controls->phy_control + 0x0c);
	u32 pcs = readl(controls->phy_control + 0x10);
	/*
	 * OEM ca-ne.ko reads the lane status from SGMII_LP_REGS + 0xf4, not
	 * from GLOBAL_PHY_SGMII_PCS_INFO (__p4_sds_status_get, ca-ne.ko+0x1b080):
	 * bit8 -> link, bit4 -> flag, bit0 -> flag. The PCS_INFO fields are all
	 * named *_s0, so they describe the s0 channel while this board routes
	 * the 2.5G PHY over s3 (s3_pcie_usb3_sgmii_sel = 2). Read the OEM
	 * register too so the two can be compared.
	 */
	u32 lp = controls->sgmii_lp ? readl(controls->sgmii_lp + 0xf4) : 0;

	return sysfs_emit(buf,
		"status=%08x info=%08x misc=%08x pcs=%08x lp=%08x "
		"ckusable_sgmii=%u link_ok=%u reg_rdy=%u sdet=%u sts_upd_rx=%u "
		"sym_err=%u partner=%05x lp_link=%u lp_b4=%u lp_b0=%u\n",
		status, info, misc, pcs, lp,
		(status >> 7) & 1, info & 1, (info >> 1) & 1, (info >> 2) & 1,
		(info >> 3) & 1, (info >> 4) & 1, (info >> 5) & 0x1ffff,
		(lp >> 8) & 1, (lp >> 4) & 1, lp & 1);
}

static const struct of_device_id rtl_pcie_controls_match[] = {
	{.compatible = "realtek,rtl9617c-pcie-controls"},
	{},
};
MODULE_DEVICE_TABLE(of, rtl_pcie_controls_match);
static struct platform_driver rtl_pcie_controls_driver = {
	.probe = rtl_pcie_controls_probe,
	.driver = {.name = "rtl9617c-pcie-controls", .of_match_table = rtl_pcie_controls_match},
};
module_platform_driver(rtl_pcie_controls_driver);
MODULE_DESCRIPTION("Native RTL9617C PCIe clock/reset/PHY controls");
MODULE_LICENSE("GPL");
