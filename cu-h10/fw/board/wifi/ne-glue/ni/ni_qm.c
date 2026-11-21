// SPDX-License-Identifier: GPL-2.0-or-later
#include <linux/bitfield.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/io.h>
#include <linux/ip.h>
#include <linux/rcupdate.h>
#include <linux/unaligned.h>

#include "ni.h"
/* CU WiFi-NE backport: EPP ID/length helpers, RTL_WIFI_ID_MAX, source. */
#include "rtl9617c-wifi-format.h"

#define QM_EQ_PROFILE_CPU0		RTL_NI_QM_EQ_PROFILE(RTL_NI_QM_EQ)
#define QM_DQ_EQ_PRIVATE		1
#define QM_DQ_EQ_SHARED			2
#define QM_DQ_BID_BASE			512
#define QM_WAN_PORT_FIRST		16
#define QM_WAN_PORT_LAST		32
#define QM_CPU_PORT			16
#define QM_RESET_BIT			BIT(5)
#define QM_RESET_DONE			BIT(30)
#define QM_PUSH_READY			BIT(31)
#define QM_EQ_FREE_COUNT		GENMASK(13, 0)
#define QM_EPP_WRITE_MASK		GENMASK(23, 0)
#define QM_CMD_EQ			GENMASK(3, 0)
#define QM_CMD_VALID			(BIT(4) | BIT(6))
#define QM_CMD_L4_CSUM_ERR		BIT(5)
#define QM_CMD_ADDR			GENMASK(31, 7)
#define QM_HDR_EXT			BIT(31)
#define QM_HDR_POL			GENMASK(26, 18)
#define QM_HDR_LEN			GENMASK(28, 15)
#define QM_HDR_SOURCE			GENMASK(14, 9)
#define QM_SOURCE_PON			7
#define QM_SOURCE_PON_LLID		32
#define QM_EQ_CFG_DESC			0x61008060
#define QM_ATTRIBUTE_CPU		0x0a008060
#define QM_ATTRIBUTE_CPU_ENTRY		48
#define QM_INGRESS_FLUSH_CFG		0x05102013
#define QM_ES_CTRL_RUN			0x8462ff01
#define QM_TCAM_DEFAULT			0x8e308000
#define QM_TCAM_ENTRIES			16
#define QM_RING_ADDR_MASK		(RTL_NI_QM_RING_SIZE - 1)

static int rtl_ni_qm_table_write(struct rtl9617c_ni *ni, unsigned int reg,
				 u32 index)
{
	return rtl_ne_table_write(ni->regs, reg, index);
}

static int rtl_ni_qm_port_map(struct rtl9617c_ni *ni, u32 index, u32 val)
{
	rtl_ni_write(ni, RTL_NI_QM_PORT_MAP_DATA, val);
	return rtl_ni_qm_table_write(ni, RTL_NI_QM_PORT_MAP_CMD, index);
}

static int rtl_ni_qm_attribute(struct rtl9617c_ni *ni, unsigned int entry,
			       u32 val)
{
	rtl_ni_write(ni, RTL_NI_QM_ATTRIBUTE_DATA, val);
	return rtl_ni_qm_table_write(ni, RTL_NI_QM_ATTRIBUTE_CMD, entry);
}

static int rtl_ni_qm_pon_map(struct rtl9617c_ni *ni)
{
	unsigned int port, flags;
	int ret;

	for (flags = 0; flags < 256; flags += 64)
		for (port = 32; port < 64; port++) {
			ret = rtl_ni_qm_port_map(ni, flags | port, 8);
			if (ret)
				return ret;
		}
	return 0;
}

static int rtl_ni_qm_push(struct rtl9617c_ni *ni, u32 addr, unsigned int eq)
{
	u32 status;
	int ret;

	ret = regmap_read_poll_timeout_atomic(ni->regs, RTL_NI_QM_EQ_FREE(eq),
					      status, status & QM_EQ_FREE_COUNT,
					      1, 10000);
	if (ret)
		return ret;
	ret = regmap_read_poll_timeout_atomic(ni->regs, RTL_NI_QM_CPU_READY,
					      status, status & QM_PUSH_READY,
					      1, 10000);
	if (ret)
		return ret;
	rtl_ni_write(ni, RTL_NI_QM_CPU_PUSH, addr | eq);
	return 0;
}

static int rtl_ni_qm_try_push(struct rtl9617c_ni *ni, u32 addr, unsigned int eq)
{
	if (!(rtl_ni_read(ni, RTL_NI_QM_EQ_FREE(eq)) & QM_EQ_FREE_COUNT) ||
	    !(rtl_ni_read(ni, RTL_NI_QM_CPU_READY) & QM_PUSH_READY))
		return -EAGAIN;
	rtl_ni_write(ni, RTL_NI_QM_CPU_PUSH, addr | eq);
	return 0;
}

static void rtl_ni_qm_refill_add(struct rtl_ni_qm_refill *refill, u32 cmd)
{
	unsigned int eq = FIELD_GET(QM_CMD_EQ, cmd) - RTL_NI_QM_EQ;
	unsigned int tail = (refill->head[eq] + refill->count[eq]) %
			    RTL_NI_QM_EQ_BUFS;

	refill->addr[eq][tail] = cmd & QM_CMD_ADDR;
	refill->count[eq]++;
	refill->pending++;
}

static void rtl_ni_qm_refill_drain(struct rtl9617c_ni *ni, unsigned int budget)
{
	struct rtl_ni_qm_refill *refill = &ni->qm.refill;
	unsigned int eq, done = 0;

	for (eq = 0; eq < RTL_NI_QM_EQS; eq++) {
		unsigned int limit = budget / 2;

		while (refill->count[eq] && limit-- && done++ < budget) {
			if (rtl_ni_qm_try_push(ni, refill->addr[eq][refill->head[eq]],
					       eq + RTL_NI_QM_EQ))
				break;
			refill->head[eq] = (refill->head[eq] + 1) % RTL_NI_QM_EQ_BUFS;
			refill->count[eq]--;
			refill->pending--;
		}
	}
}

static int rtl_ni_qm_ingress(struct rtl9617c_ni *ni, unsigned int port)
{
	static const u32 ilpb[] = { 0xc1000b80, 0xc1800deb, 0x1800a363, 0x00108003, 1 };
	static const u32 key[] = { 0x00007ef0, 0, 0, 0, 0, 0x02800000, 0x0001fbc0,
				   0, 0, 0, 0, 0x0a000000, 0x00000a40 };
	static const u32 fib[] = { 0, 0, 0x0003c000, 0x42, 0 };
	static const u32 cpu_map[] = { 0x90, 0x50, 0xd0 };
	unsigned int i;
	int ret;

	if (port >= RTL_NI_GE_PORTS)
		port = RTL_NI_PORT_P6;

	for (i = 0; i < 256; i += 64) {
		ret = rtl_ni_qm_port_map(ni, i | port, i & 64 ? 8 : port);
		if (ret)
			return ret;
	}

	rtl_ni_write(ni, RTL_NI_QM_ILPB_DATA, port);
	ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_ILPB_CMD, port);
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(ilpb); i++)
		rtl_ni_write(ni, RTL_NI_QM_ILPB_WORDS - 4 * i, ilpb[i]);
	ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_ILPB_APPLY_CMD, port);
	if (ret)
		return ret;

	for (i = 0; i < ARRAY_SIZE(key); i++)
		rtl_ni_write(ni, RTL_NI_QM_KEY_WORDS - 4 * i, key[i]);
	ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_KEY_CMD, 0);
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(fib); i++)
		rtl_ni_write(ni, RTL_NI_QM_FIB_WORDS - 4 * i, fib[i]);
	ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_FIB_CMD, 0);
	if (ret)
		return ret;

	ret = rtl_ni_qm_port_map(ni, QM_CPU_PORT, 9);
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(cpu_map); i++) {
		ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_PORT_MAP_CMD, cpu_map[i]);
		if (ret)
			return ret;
	}

	rtl_ni_write(ni, RTL_NI_QM_PORT_ATTR_A_DATA3, ~(port << 6));
	rtl_ni_write(ni, RTL_NI_QM_PORT_ATTR_A_DATA2, ~0U);
	rtl_ni_write(ni, RTL_NI_QM_PORT_ATTR_A_DATA, ~0U);
	ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_PORT_ATTR_A_CMD, port);
	if (ret)
		return ret;
	rtl_ni_write(ni, RTL_NI_QM_PORT_ATTR_A_DATA3, ~0xfc0U | (port << 6));
	rtl_ni_write(ni, RTL_NI_QM_PORT_ATTR_A_DATA2, ~0U);
	rtl_ni_write(ni, RTL_NI_QM_PORT_ATTR_A_DATA, ~0U);
	ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_PORT_ATTR_A_CMD, 512 + port);
	if (ret)
		return ret;
	rtl_ni_write(ni, RTL_NI_QM_PORT_ATTR_B_DATA3, 0);
	rtl_ni_write(ni, RTL_NI_QM_PORT_ATTR_B_DATA2, (3 << 5) | (16 << 8));
	rtl_ni_write(ni, RTL_NI_QM_PORT_ATTR_B_DATA, BIT(6));
	ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_PORT_ATTR_B_CMD, port);
	if (ret)
		return ret;
	rtl_ni_write(ni, RTL_NI_QM_CPU_PORT_EN, BIT(1));
	rtl_ni_write(ni, RTL_NI_QM_CPU_PORT_CFG, 0);
	ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_CPU_PORT_CMD, QM_CPU_PORT);
	if (ret)
		return ret;

	rtl_ni_rmw(ni, RTL_NI_NITX_THROTTLE, GENMASK(15, 0), 0);
	rtl_ni_rmw(ni, RTL_NI_NITX_THROTTLE_2, GENMASK(15, 0), 0);
	rtl_ni_rmw(ni, RTL_NI_QM_RX_ENABLE, 0, BIT(0) | BIT(1));
	return 0;
}

static int rtl_ni_qm_deepq(struct rtl9617c_ni *ni)
{
	unsigned int count = RTL_NI_DQ_BUFS;
	unsigned int low = (count * 2) / 3;
	unsigned int high = low * 2;
	unsigned int pool, port, voq;
	u32 base = lower_32_bits(ni->qm.dq_dma);
	int ret;

	rtl_ni_rmw(ni, RTL_NI_PUC_DEQUEUE, GENMASK(15, 0), 0);
	for (pool = 0; pool < 2; pool++) {
		unsigned int cfg = RTL_NI_QM_EQ_CFG(QM_DQ_EQ_PRIVATE + pool);

		rtl_ni_write(ni, cfg, (base + pool * count * RTL_NI_DQ_BUF_SIZE) | 1);
		rtl_ni_write(ni, cfg + 4, (count << 16) | (QM_DQ_BID_BASE + pool * count));
		rtl_ni_write(ni, cfg + 8, 5);
		rtl_ni_write(ni, cfg + 12, QM_EQ_CFG_DESC);
		rtl_ni_write(ni, cfg + 16, 2);
	}
	rtl_ni_write(ni, RTL_NI_QM_EQ_PROFILE(1),
		     QM_DQ_EQ_PRIVATE | (QM_DQ_EQ_SHARED << 4));
	rtl_ni_rmw(ni, RTL_NI_QM_DQ_CFG, GENMASK(3, 0), 10);
	rtl_ni_rmw(ni, RTL_NI_QM_BUF_CFG, 0xc8000000, 0);
	rtl_ni_write(ni, RTL_NI_QM_DQ_THRESHOLD, low | (high << 16));
	rtl_ni_write(ni, RTL_NI_QM_GROUP_THRESHOLD, 0x3fff3fff);
	rtl_ni_write(ni, RTL_NI_QM_PORT_PROFILE, ~0U);
	rtl_ni_write(ni, RTL_NI_QM_VOQ_CFG, 0);
	rtl_ni_write(ni, RTL_NI_QM_VOQ_WEIGHT, (25U << 24) | (0x3fffU << 10) | 0x3ff);
	rtl_ni_write(ni, RTL_NI_QM_VOQ_THRESHOLD, low | (count << 14) | 0xf0000000);
	ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_VOQ_CMD, 3);
	if (ret)
		return ret;

	for (port = QM_WAN_PORT_FIRST; port < QM_WAN_PORT_LAST; port++) {
		rtl_ni_write(ni, RTL_NI_QM_CPU_EQ(port), 1);
		rtl_ni_write(ni, RTL_NI_QM_QUEUE_ENABLE(port), 255);
		rtl_ni_write(ni, RTL_NI_QM_PORT_WEIGHT(port), 0x01010101);
		rtl_ni_write(ni, RTL_NI_QM_PORT_WEIGHT(port) + 4, 0x01010101);
		rtl_ni_write(ni, RTL_NI_QM_CPU_CFG,
			     count | BIT(14) | (count << 16) | BIT(30));
		ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_CPU_CFG_CMD, port);
		if (ret)
			return ret;
		for (voq = port * 8; voq < port * 8 + 8; voq++) {
			rtl_ni_write(ni, RTL_NI_QM_VOQ_PROFILE, 3);
			ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_VOQ_PROFILE_CMD, voq);
			if (ret)
				return ret;
		}
	}
	return 0;
}

static void rtl_ni_qm_axi_reorder(struct rtl9617c_ni *ni)
{
	static const struct {
		u16 offset;
		u32 ctrl;
		u32 user;
		u32 id;
	} ch[] = {
		{ 0x000, 15, BIT(31) | 12, BIT(31) | 13 },
		{ 0x400, 15, BIT(31) | 12, BIT(31) | 13 },
		{ 0x480, 2, BIT(31) | 8, BIT(31) | 9 },
	};
	void __iomem *base = ni->qm.axi;
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(ch); i++) {
		void __iomem *reg = base + ch[i].offset;

		writel(ch[i].ctrl, reg);
		writel(ch[i].user, reg + 0x04);
		writel(BIT(28), reg + 0x08);
		writel(BIT(28), reg + 0x0c);
		writel(ch[i].id, reg + 0x10);
	}
}

static int rtl_ni_qm_cpu_credits(struct rtl9617c_ni *ni)
{
	u32 select = rtl_ni_read(ni, RTL_NI_QM_CPU_SELECT);
	unsigned int profile, cpu, voq;
	int ret;

	for (profile = 0; profile < 2; profile++) {
		unsigned int count = profile ? RTL_NI_QM_PE_BUFS - 4 : RTL_NI_QM_EQ_BUFS;

		rtl_ni_write(ni, RTL_NI_QM_CPU_BUDGET(profile),
			     (count / 8) << 16 | (count / 64));
		rtl_ni_write(ni, RTL_NI_QM_CPU_BURST(profile), 0x3fff3fff);
	}

	for (cpu = 0; cpu < 4; cpu++) {
		unsigned int count0, count1, eq_profile;

		if (cpu == 1)
			continue;
		profile = cpu ? 1 : 0;
		count0 = cpu ? RTL_NI_QM_PE_BUFS - 4 : RTL_NI_QM_EQ_BUFS;
		count1 = cpu ? 0 : RTL_NI_QM_EQ_BUFS;
		eq_profile = cpu ? cpu + 4 : RTL_NI_QM_EQ;

		if (cpu) {
			unsigned int eq = RTL_NI_QM_PE_EQ + (3 - cpu);

			rtl_ni_write(ni, RTL_NI_QM_EQ_PROFILE(eq_profile), eq | (15 << 4));
			rtl_ni_write(ni, RTL_NI_QM_CPU_EQ(cpu), eq_profile);
		}
		rtl_ni_write(ni, RTL_NI_QM_CPU_CFG,
			     count0 | BIT(14) | (count1 << 16) | BIT(30));
		ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_CPU_CFG_CMD, cpu);
		if (ret)
			return ret;
		select = (select & ~(3U << (cpu * 2))) | (profile << (cpu * 2));

		rtl_ni_write(ni, RTL_NI_QM_EQ_WEIGHT(eq_profile), 12 | (12 << 16));
		for (voq = cpu * 8; voq < cpu * 8 + 8; voq++) {
			if (cpu)
				rtl_ni_write(ni, RTL_NI_QM_VOQ_EQ(voq), eq_profile);
			rtl_ni_write(ni, RTL_NI_QM_VOQ_PROFILE, cpu == 3 ? 4 : profile);
			ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_VOQ_PROFILE_CMD, voq);
			if (ret)
				return ret;
		}
	}

	for (profile = 0; profile < 3; profile++) {
		unsigned int count = profile ? RTL_NI_QM_PE_BUFS - 4 : RTL_NI_QM_EQ_BUFS;

		rtl_ni_write(ni, RTL_NI_QM_VOQ_CFG, 0);
		rtl_ni_write(ni, RTL_NI_QM_VOQ_WEIGHT, (profile == 1 ? 12 : 3) << 24);
		rtl_ni_write(ni, RTL_NI_QM_VOQ_THRESHOLD,
			     ((count * 7 / 8) << 14) | (count * 6 / 8));
		ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_VOQ_CMD,
					    profile == 2 ? 4 : profile);
		if (ret)
			return ret;
	}
	rtl_ni_write(ni, RTL_NI_QM_CPU_SELECT, select);
	return 0;
}

int rtl_ni_qm_alloc(struct rtl9617c_ni *ni)
{
	struct rtl_ni_qm *qm = &ni->qm;

	qm->buf = dma_alloc_noncoherent(ni->dev, RTL_NI_QM_BUFS * RTL_NI_QM_BUF_SIZE,
					&qm->buf_dma, DMA_FROM_DEVICE, GFP_KERNEL);
	if (!qm->buf)
		return -ENOMEM;
	qm->ring = dmam_alloc_coherent(ni->dev, RTL_NI_QM_RING_SIZE * RTL_NI_QM_VOQS,
				       &qm->ring_dma, GFP_KERNEL);
	qm->dq = dmam_alloc_coherent(ni->dev, RTL_NI_DQ_SIZE, &qm->dq_dma,
				     GFP_KERNEL);
	if (!qm->ring || !qm->dq) {
		rtl_ni_qm_free(ni);
		return -ENOMEM;
	}
	return 0;
}

void rtl_ni_qm_free(struct rtl9617c_ni *ni)
{
	struct rtl_ni_qm *qm = &ni->qm;

	if (!qm->buf)
		return;
	dma_free_noncoherent(ni->dev, RTL_NI_QM_BUFS * RTL_NI_QM_BUF_SIZE, qm->buf,
			     qm->buf_dma, DMA_FROM_DEVICE);
	qm->buf = NULL;
}

int rtl_ni_qm_start(struct rtl9617c_ni *ni)
{
	struct rtl_ni_qm *qm = &ni->qm;
	unsigned int i;
	u32 val;
	int ret;

	qm->ready = false;
	rtl_ni_rmw(ni, RTL_NI_QM_CB_CTRL, BIT(31), 0);
	rtl_ni_rmw(ni, RTL_NI_QM_RMU_CTRL, BIT(31), 0);
	rtl_ni_rmw(ni, RTL_NI_QM_ES_CTRL, BIT(31), 0);

	writel(readl(ni->reset) | QM_RESET_BIT, ni->reset);
	usleep_range(1000, 2000);
	writel(readl(ni->reset) & ~QM_RESET_BIT, ni->reset);
	ret = regmap_read_poll_timeout(ni->regs, RTL_NI_QM_RESET_STATUS, val,
				       val & QM_RESET_DONE, 1, 100000);
	if (ret)
		return ret;

	memset(&qm->refill, 0, sizeof(qm->refill));
	rtl_ni_rmw(ni, RTL_NI_QM_RMU_CTRL, BIT(31), 0);
	rtl_ni_rmw(ni, RTL_NI_QM_ES_CTRL, BIT(31), 0);
	rtl_ni_write(ni, RTL_NI_QM_EQ_IRQ_ENABLE_LO, 0);
	rtl_ni_write(ni, RTL_NI_QM_EQ_IRQ_ENABLE_HI, 0);

	for (i = 0; i < RTL_NI_QM_VOQS; i++) {
		qm->read[i] = rtl_ni_read(ni, RTL_NI_QM_EPP_WRITE(i)) & QM_RING_ADDR_MASK;
		rtl_ni_write(ni, RTL_NI_QM_EPP_READ(i), qm->read[i]);
	}
	rtl_ni_read(ni, RTL_NI_QM_EPP_READ(0));
	rtl_ni_qm_axi_reorder(ni);
	memset(qm->ring, 0, RTL_NI_QM_RING_SIZE * RTL_NI_QM_VOQS);
	dma_sync_single_for_device(ni->dev, qm->buf_dma,
				   RTL_NI_QM_BUFS * RTL_NI_QM_BUF_SIZE,
				   DMA_FROM_DEVICE);

	for (i = 0; i < 16; i++) {
		rtl_ni_write(ni, RTL_NI_QM_EQ_CFG(i), 0);
		rtl_ni_write(ni, RTL_NI_QM_EQ_CFG(i) + 4, 0);
	}
	for (i = 0; i < RTL_NI_QM_EQS; i++) {
		unsigned int cfg = RTL_NI_QM_EQ_CFG(RTL_NI_QM_EQ + i);

		rtl_ni_write(ni, cfg, 1);
		rtl_ni_write(ni, cfg + 4, (RTL_NI_QM_EQ_BUFS << 16) |
			     (i * RTL_NI_QM_EQ_BUFS));
		rtl_ni_write(ni, cfg + 8, 5 | BIT(3) | (24 << 8));
		rtl_ni_write(ni, cfg + 12, QM_EQ_CFG_DESC);
		rtl_ni_write(ni, cfg + 16, 2);
	}

	ret = rtl_ni_qm_deepq(ni);
	if (ret)
		return ret;

	rtl_ni_write(ni, QM_EQ_PROFILE_CPU0, RTL_NI_QM_EQ | ((RTL_NI_QM_EQ + 1) << 4));
	rtl_ni_write(ni, RTL_NI_QM_CPU_EQ(0), RTL_NI_QM_EQ);
	rtl_ni_write(ni, RTL_NI_QM_PACKET_LAYOUT, 0x18041804);
	rtl_ni_write(ni, RTL_NI_QM_INGRESS_CFG, QM_INGRESS_FLUSH_CFG);
	rtl_ni_write(ni, RTL_NI_QM_FLUSH, 0xffff);
	rtl_ni_write(ni, RTL_NI_QM_FLUSH, 0);
	rtl_ni_write(ni, RTL_NI_QM_INGRESS_CFG, 0);

	for (i = 0; i < 16; i++) {
		ret = rtl_ni_qm_attribute(ni, i, 0);
		if (ret)
			return ret;
	}
	ret = rtl_ni_qm_attribute(ni, QM_ATTRIBUTE_CPU_ENTRY, QM_ATTRIBUTE_CPU);
	if (ret)
		return ret;

	rtl_ni_rmw(ni, RTL_NI_QM_CONTROL, BIT(11) | BIT(13), 0xff);
	rtl_ni_rmw(ni, RTL_NI_QM_STATUS, 0, BIT(2));
	rtl_ni_write(ni, RTL_NI_QM_DROP_CFG, 0);

	rtl_ni_rmw(ni, RTL_NI_QM_EQ_QUEUE(RTL_NI_QM_EQ), GENMASK(28, 0),
		   ((RTL_NI_QM_RING_SIZE / 16) << 8) | 0xf2);
	for (i = 0; i < RTL_NI_QM_VOQS; i++) {
		rtl_ni_write(ni, RTL_NI_QM_VOQ_EQ(i), RTL_NI_QM_EQ);
		rtl_ni_write(ni, RTL_NI_QM_EPP_BASE(i),
			     qm->ring_dma + i * RTL_NI_QM_RING_SIZE);
	}
	for (i = 0; i < RTL_NI_QM_BUFS; i++) {
		ret = rtl_ni_qm_push(ni, qm->buf_dma + i * RTL_NI_QM_BUF_SIZE,
				     RTL_NI_QM_EQ + i / RTL_NI_QM_EQ_BUFS);
		if (ret)
			return ret;
	}

	ret = rtl_ni_qm_cpu_credits(ni);
	if (ret)
		return ret;
	rtl_ni_write(ni, RTL_NI_QM_QUEUE_ENABLE(0), 0xff);
	rtl_ni_rmw(ni, RTL_NI_NITX_BACKPRESSURE, GENMASK(7, 0), 0);

	for (i = 0; i < RTL_NI_PORTS; i++) {
		if (!ni->ports[i])
			continue;
		ret = rtl_ni_qm_ingress(ni, i);
		if (ret)
			return ret;
	}
	ret = rtl_ni_qm_pon_map(ni);
	if (ret)
		return ret;

	for (i = 0; i < QM_TCAM_ENTRIES; i++) {
		rtl_ni_write(ni, RTL_NI_QM_TCAM_DATA, QM_TCAM_DEFAULT);
		ret = rtl_ni_qm_table_write(ni, RTL_NI_QM_TCAM_CMD, i);
		if (ret)
			return ret;
	}

	rtl_ni_rmw(ni, RTL_NI_L2TM_ES_CTRL, 0, BIT(8) | BIT(9));
	rtl_ni_write(ni, RTL_NI_PORT_TABLE_ENTRY(8), 0xff | (6 << 16));
	rtl_ni_write(ni, RTL_NI_PORT_TABLE_ENTRY(9), 0xff | (6 << 16));
	rtl_ni_rmw(ni, RTL_NI_QM_CB_CTRL, 0, BIT(31));
	rtl_ni_rmw(ni, RTL_NI_QM_CLOCK_CTRL, 0, BIT(2));
	rtl_ni_write(ni, RTL_NI_QM_ES_CTRL, QM_ES_CTRL_RUN);
	rtl_ni_rmw(ni, RTL_NI_PUC_DEQUEUE, 0, GENMASK(15, 0));
	rtl_ni_rmw(ni, RTL_NI_QM_RMU_CTRL, 0, BIT(31));
	qm->ready = true;
	return 0;
}

void rtl_ni_qm_stop(struct rtl9617c_ni *ni)
{
	ni->qm.ready = false;
	rtl_ni_rmw(ni, RTL_NI_QM_CB_CTRL, BIT(31), 0);
	rtl_ni_rmw(ni, RTL_NI_PUC_DEQUEUE, GENMASK(15, 0), 0);
	rtl_ni_rmw(ni, RTL_NI_QM_RMU_CTRL, BIT(31), 0);
	rtl_ni_rmw(ni, RTL_NI_QM_ES_CTRL, BIT(31), 0);
}

static bool rtl_ni_rx_csum_valid(u32 cmd, const u8 *frame, unsigned int len)
{
	const struct iphdr *ip;
	unsigned int total, payload;
	const u8 *l4;

	if ((cmd & QM_CMD_L4_CSUM_ERR) || len < ETH_HLEN + sizeof(*ip) + 8 ||
	    get_unaligned_be16(frame + 12) != ETH_P_IP)
		return false;

	ip = (const struct iphdr *)(frame + ETH_HLEN);
	if (frame[ETH_HLEN] != 0x45 || (frame[ETH_HLEN + 6] & 0x3f) ||
	    frame[ETH_HLEN + 7])
		return false;

	total = get_unaligned_be16(&ip->tot_len);
	if (total < sizeof(*ip) + 8 || total > len - ETH_HLEN)
		return false;
	payload = total - sizeof(*ip);
	l4 = frame + ETH_HLEN + sizeof(*ip);

	switch (ip->protocol) {
	case IPPROTO_TCP:
		return payload >= 20 && (l4[12] >> 4) >= 5 &&
		       (l4[12] >> 4) * 4 <= payload;
	case IPPROTO_UDP:
		return get_unaligned_be16(l4 + 4) == payload && (l4[6] || l4[7]);
	default:
		return false;
	}
}

static void rtl_ni_qm_retire(struct rtl9617c_ni *ni, unsigned int voq, u32 cmd,
			     bool refill)
{
	struct rtl_ni_qm *qm = &ni->qm;

	qm->read[voq] = (qm->read[voq] + RTL_NI_QM_CMD_SIZE) & QM_RING_ADDR_MASK;
	mb();
	rtl_ni_write(ni, RTL_NI_QM_EPP_READ(voq), qm->read[voq]);
	if (refill) {
		u32 offset = (cmd & QM_CMD_ADDR) - lower_32_bits(qm->buf_dma);

		dma_sync_single_for_device(ni->dev, qm->buf_dma + offset,
					   RTL_NI_QM_BUF_SIZE, DMA_FROM_DEVICE);
		rtl_ni_qm_refill_add(&qm->refill, cmd);
	}
}

/* CU WiFi-NE backport: hand an EPP carrying a Wi-Fi interface ID back to the
 * matching AP netdev through its registered endpoint ->receive(). */
static void rtl_ni_qm_deliver_wifi(struct rtl9617c_ni *ni,
				   struct sk_buff *skb, unsigned int id,
				   bool forwarded)
{
	struct rtl9617c_ni_wifi_endpoint *endpoint;

	rcu_read_lock();
	endpoint = id <= RTL_WIFI_ID_MAX ? rcu_dereference(ni->wifi[id]) : NULL;
	if (endpoint && netif_running(endpoint->netdev)) {
		skb->dev = endpoint->netdev;
		skb->priority = 0;
		endpoint->receive(endpoint, skb, forwarded);
	} else {
		atomic_long_inc(&ni->rx_dropped);
		dev_kfree_skb_any(skb);
	}
	rcu_read_unlock();
}

static void rtl_ni_qm_deliver(struct rtl9617c_ni *ni, struct napi_struct *napi,
			      struct sk_buff *skb, u32 cmd, u32 h0, u32 h1,
			      bool csum)
{
	unsigned int source = FIELD_GET(QM_HDR_SOURCE, h1);
	struct rtl9617c_ni_endpoint *endpoint;
	struct net_device *dev;

	rcu_read_lock();
	if (source >= RTL_NI_PORTS) {
		endpoint = rcu_dereference(ni->pon);
		if (endpoint && (source == QM_SOURCE_PON ||
				 source >= QM_SOURCE_PON_LLID)) {
			if (csum && rtl_ni_rx_csum_valid(cmd, skb->data, skb->len))
				skb->ip_summed = CHECKSUM_UNNECESSARY;
			endpoint->receive(endpoint, napi, skb,
					  source | (FIELD_GET(QM_HDR_POL, h0) << 8));
		} else {
			atomic_long_inc(&ni->rx_dropped);
			dev_kfree_skb_any(skb);
		}
		rcu_read_unlock();
		return;
	}

	dev = rcu_dereference(ni->rx_dev[source]);
	if (!dev || !netif_running(dev)) {
		atomic_long_inc(&ni->rx_dropped);
		dev_kfree_skb_any(skb);
		rcu_read_unlock();
		return;
	}
	if (csum && (dev->features & NETIF_F_RXCSUM) &&
	    rtl_ni_rx_csum_valid(cmd, skb->data, skb->len))
		skb->ip_summed = CHECKSUM_UNNECESSARY;
	skb->protocol = eth_type_trans(skb, dev);
	DEV_STATS_INC(dev, rx_packets);
	DEV_STATS_ADD(dev, rx_bytes, skb->len + ETH_HLEN);
	napi_gro_receive(napi, skb);
	rcu_read_unlock();
}

int rtl_ni_qm_poll(struct rtl9617c_ni *ni, struct napi_struct *napi, int budget)
{
	struct rtl_ni_qm *qm = &ni->qm;
	bool csum = rtl_ni_read(ni, RTL_FE_CAM_DATA_AUX) & RTL_FE_CAM_AUX_L4_CSUM;
	int voq, count = 0;

	rtl_ni_qm_refill_drain(ni, NAPI_POLL_WEIGHT);

	for (voq = RTL_NI_QM_VOQS - 1; voq >= 0 && count < budget; voq--) {
		bool nonempty = rtl_ni_read(ni, RTL_NI_QM_VOQ_STATUS) & BIT(voq);
		unsigned int wr = rtl_ni_read(ni, RTL_NI_QM_EPP_WRITE(voq)) &
				  QM_EPP_WRITE_MASK;
		bool full = qm->read[voq] == wr && nonempty;

		while ((qm->read[voq] != wr || full) && count < budget) {
			void *entry = qm->ring + voq * RTL_NI_QM_RING_SIZE + qm->read[voq];
			unsigned int eq, len, hdr, wifi_id = 0;
			bool wifi_forwarded;
			struct sk_buff *skb;
			u32 cmd, length_word, offset, h0, h1;
			void *data;

			full = false;
			dma_rmb();
			cmd = get_unaligned_le32(entry);
			length_word = get_unaligned_le32(entry + 4);
			eq = FIELD_GET(QM_CMD_EQ, cmd);
			if ((eq == RTL_NI_QM_EQ || eq == RTL_NI_QM_EQ + 1) &&
			    qm->refill.count[eq - RTL_NI_QM_EQ] == RTL_NI_QM_EQ_BUFS)
				break;

			count++;
			offset = (cmd & QM_CMD_ADDR) - lower_32_bits(qm->buf_dma);
			if (offset >= RTL_NI_QM_BUFS * RTL_NI_QM_BUF_SIZE ||
			    (eq != RTL_NI_QM_EQ && eq != RTL_NI_QM_EQ + 1)) {
				atomic_long_inc(&ni->rx_errors);
				rtl_ni_qm_retire(ni, voq, cmd, false);
				continue;
			}

			dma_sync_single_for_cpu(ni->dev, qm->buf_dma + offset,
						RTL_NI_QM_BUF_SIZE, DMA_FROM_DEVICE);
			data = qm->buf + offset + RTL_NI_QM_HEADROOM;
			h0 = get_unaligned_be32(data);
			h1 = get_unaligned_be32(data + 4);
			hdr = (h0 & QM_HDR_EXT) ? 16 : 8;
			len = FIELD_GET(QM_HDR_LEN, h1);
			if (h0 & QM_HDR_EXT)
				len -= 8;
			/* CU WiFi-NE backport: an EPP carrying a nonzero interface ID is
			 * a Wi-Fi frame. Its compact length includes two internal
			 * eight-byte headers; skip them and use the embedded payload. */
			wifi_id = rtl_wifi_epp_id(length_word);
			wifi_forwarded = !!wifi_id;
			if (wifi_forwarded) {
				int payload = rtl_wifi_epp_length(length_word,
					RTL_NI_QM_DATA_SIZE - RTL_WIFI_INTERNAL_BYTES);
				if (payload < 0) {
					atomic_long_inc(&ni->rx_errors);
					rtl_ni_qm_retire(ni, voq, cmd, true);
					continue;
				}
				len = payload;
				hdr = RTL_WIFI_INTERNAL_BYTES;
			}
			/* Base parity (rtl9617c-qm.c): an NE lookup miss returns with
			 * EPP id 0, WiFi source and the full-Header-A bit; the real ID
			 * lives in Header A metadata byte. Without this branch every
			 * WiFi->LAN frame is routed to the PON decoder and dropped. */
			if (!wifi_forwarded) {
				unsigned int source = FIELD_GET(QM_HDR_SOURCE, h1);

				if (source == RTL_WIFI_SOURCE && (h0 & BIT(31))) {
					u32 metadata = get_unaligned_be32(data + 12);
					if (((metadata >> 8) & 15) != 15)
						wifi_id = metadata & 255;
				}
			}
			if ((cmd & QM_CMD_VALID) != QM_CMD_VALID || len < ETH_HLEN ||
			    len > RTL_NI_QM_DATA_SIZE - hdr) {
				atomic_long_inc(&ni->rx_errors);
				rtl_ni_qm_retire(ni, voq, cmd, true);
				continue;
			}

			skb = napi_alloc_skb(napi, len);
			if (!skb) {
				atomic_long_inc(&ni->rx_dropped);
				rtl_ni_qm_retire(ni, voq, cmd, true);
				continue;
			}
			skb_put_data(skb, data + hdr, len);
			rtl_ni_qm_retire(ni, voq, cmd, true);
			if (wifi_id)
				rtl_ni_qm_deliver_wifi(ni, skb, wifi_id,
						       wifi_forwarded);
			else
				rtl_ni_qm_deliver(ni, napi, skb, cmd, h0, h1, csum);
		}
	}

	rtl_ni_qm_refill_drain(ni, NAPI_POLL_WEIGHT);
	return count;
}
