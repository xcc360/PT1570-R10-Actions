// SPDX-License-Identifier: GPL-2.0-or-later
#include <linux/bits.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/skbuff.h>
#include <linux/unaligned.h>

#include "ni.h"
/* CU WiFi-NE backport: rtl_wifi_lookup_control() / RTL_WIFI_ID_MAX / source. */
#include "rtl9617c-wifi-format.h"

#define DMA_CTRL			0x000
#define DMA_CTRL_ENABLE			BIT(0)
#define DMA_CTRL_RUN			(BIT(0) | (3 << 2) | BIT(4))
#define DMA_CTRL_RESET			BIT(8)
#define DMA_AXI_USER_SELECT		0x014
#define DMA_AXI_USER_PATTERN1		0x01c
#define DMA_AXI_USER_PATTERN1_INIT	0x02008080
#define DMA_VP(n)			(0x100 + (n) * 0xa0)
#define DMA_VP_ENABLE			0x00
#define DMA_VP_BASE_ACCESS		0x04
#define DMA_VP_BASE_ACCESS_BUSY		BIT(31)
#define DMA_VP_BASE_ACCESS_WRITE	BIT(30)
#define DMA_VP_BASE_HIGH		0x08
#define DMA_VP_BASE_HIGH_INIT		2
#define DMA_VP_BASE_LOW			0x0c
#define DMA_VP_WRITE			0x18
#define DMA_VP_READ			0x1c
#define DMA_VP_IRQ_ENABLE		0x64
#define DMA_VP_MISC_IRQ			0x68
#define DMA_VP_HEADER_A			0x78
#define DMA_VP_HEADER_A_INIT		BIT(9)
#define DMA_SS_CTRL			0x900
#define DMA_AXI_CONFIG			0xd80
#define DMA_AXI_CONFIG_MASK		GENMASK(14, 0)
#define DMA_AXI_CONFIG_INIT		0x7aff
#define DMA_AFT_CTRL			0xf00
#define DMA_AFT_CTRL_INIT		((64 << 4) | BIT(0))

#define DMA_DESC_CTRL			0x61000002
#define DMA_DESC_CTRL_OAM		0x61000000
#define DMA_DESC_LEN_SHIFT		8
#define DMA_HDR_LOW_LEN			GENMASK(28, 15)
#define DMA_MIN_FRAME			60U

#define DMA_MEM_SIZE			(RTL_NI_DMA_ENTRIES * \
					 (sizeof(struct rtl_ni_dma_desc) + \
					  RTL_NI_DMA_BUF_SIZE))

static void __iomem *rtl_ni_dma_vp(struct rtl_ni_dma *dma)
{
	return dma->base + DMA_VP(RTL_NI_DMA_VP);
}

static unsigned int rtl_ni_dma_buf_offset(unsigned int index)
{
	return RTL_NI_DMA_ENTRIES * sizeof(struct rtl_ni_dma_desc) +
	       index * RTL_NI_DMA_BUF_SIZE;
}

int rtl_ni_dma_alloc(struct rtl9617c_ni *ni)
{
	struct rtl_ni_dma *dma = &ni->dma;

	dma->mem = dmam_alloc_coherent(ni->dev, DMA_MEM_SIZE, &dma->mem_dma,
				       GFP_KERNEL);
	if (!dma->mem)
		return -ENOMEM;
	dma->desc = dma->mem;
	return 0;
}

int rtl_ni_dma_start(struct rtl_ni_dma *dma)
{
	void __iomem *vp = rtl_ni_dma_vp(dma);
	void __iomem *base = dma->base;
	u32 val;
	int ret;

	writel(readl(base + DMA_CTRL) | DMA_CTRL_RESET, base + DMA_CTRL);
	udelay(10);
	writel(readl(base + DMA_CTRL) & ~(DMA_CTRL_RESET | DMA_CTRL_ENABLE),
	       base + DMA_CTRL);
	writel(0, vp + DMA_VP_ENABLE);
	writel(0, vp + DMA_VP_IRQ_ENABLE);
	writel(0, vp + DMA_VP_WRITE);

	memset(dma->mem, 0, DMA_MEM_SIZE);
	dma->head = 0;
	dma->tail = 0;

	writel(lower_32_bits(dma->mem_dma) | RTL_NI_DMA_ORDER, vp + DMA_VP_BASE_LOW);
	writel(DMA_VP_BASE_HIGH_INIT, vp + DMA_VP_BASE_HIGH);
	writel(DMA_VP_BASE_ACCESS_BUSY | DMA_VP_BASE_ACCESS_WRITE,
	       vp + DMA_VP_BASE_ACCESS);
	ret = readl_poll_timeout_atomic(vp + DMA_VP_BASE_ACCESS, val,
					!(val & DMA_VP_BASE_ACCESS_BUSY), 1,
					100000);
	if (ret)
		return ret;
	writel((RTL_NI_CPU_PORT << 3) | DMA_VP_HEADER_A_INIT, vp + DMA_VP_HEADER_A);

	val = readl(base + DMA_AXI_USER_SELECT);
	val &= ~(3U << (RTL_NI_DMA_VP * 2));
	val |= 1U << (RTL_NI_DMA_VP * 2);
	writel(val, base + DMA_AXI_USER_SELECT);
	writel(DMA_AXI_USER_PATTERN1_INIT, base + DMA_AXI_USER_PATTERN1);
	val = readl(base + DMA_AXI_CONFIG);
	writel((val & ~DMA_AXI_CONFIG_MASK) | DMA_AXI_CONFIG_INIT,
	       base + DMA_AXI_CONFIG);
	writel(readl(base + DMA_SS_CTRL) | BIT(31) | BIT(RTL_NI_DMA_VP),
	       base + DMA_SS_CTRL);

	writel(DMA_AFT_CTRL_INIT, base + DMA_AFT_CTRL);
	writel(BIT(0), vp + DMA_VP_ENABLE);
	writel(DMA_CTRL_RUN, base + DMA_CTRL);
	return 0;
}

void rtl_ni_dma_stop(struct rtl_ni_dma *dma)
{
	void __iomem *base = dma->base;

	writel(0, rtl_ni_dma_vp(dma) + DMA_VP_ENABLE);
	writel(readl(base + DMA_CTRL) & ~DMA_CTRL_ENABLE, base + DMA_CTRL);
	writel(readl(base + DMA_CTRL) | DMA_CTRL_RESET, base + DMA_CTRL);
	udelay(10);
	writel(readl(base + DMA_CTRL) & ~DMA_CTRL_RESET, base + DMA_CTRL);
}

void rtl_ni_dma_reclaim(struct rtl_ni_dma *dma)
{
	unsigned int hw = readl(rtl_ni_dma_vp(dma) + DMA_VP_READ) &
			  (RTL_NI_DMA_ENTRIES - 1);

	while (((hw - dma->tail) & (RTL_NI_DMA_ENTRIES - 1)) > RTL_NI_DMA_GUARD)
		dma->tail = (dma->tail + 1) & (RTL_NI_DMA_ENTRIES - 1);
}

bool rtl_ni_dma_avail(struct rtl_ni_dma *dma)
{
	return ((dma->tail - dma->head - 1) & (RTL_NI_DMA_ENTRIES - 1)) >
	       RTL_NI_DMA_GUARD;
}

int rtl_ni_dma_xmit(struct rtl_ni_dma *dma, struct sk_buff *skb,
		    const struct rtl9617c_ni_frame *frame)
{
	unsigned int offset = rtl_ni_dma_buf_offset(dma->head);
	unsigned int prefix = frame->prefix_length;
	unsigned int len;
	void *buf;
	u32 low;

	len = frame->raw_payload ? skb->len : max(skb->len, DMA_MIN_FRAME);
	len += prefix;
	if (len + RTL_NI_DMA_HDR_LEN > RTL_NI_DMA_BUF_SIZE)
		return -EMSGSIZE;

	rtl_ni_dma_reclaim(dma);
	if (!rtl_ni_dma_avail(dma))
		return -ENOSPC;

	buf = dma->mem + offset;
	memset(buf, 0, len + RTL_NI_DMA_HDR_LEN);
	put_unaligned_le32(len, buf + 4);
	put_unaligned_le32(frame->header_high, buf + 8);
	low = frame->header_low;
	if (!(low & DMA_HDR_LOW_LEN))
		low |= len << 15;
	put_unaligned_le32(low, buf + 12);
	if (prefix)
		memcpy(buf + RTL_NI_DMA_HDR_LEN, frame->prefix, prefix);
	skb_copy_bits(skb, 0, buf + RTL_NI_DMA_HDR_LEN + prefix, skb->len);

	dma->desc[dma->head].addr = cpu_to_le32(dma->mem_dma + offset);
	dma->desc[dma->head].ctrl = cpu_to_le32((frame->oam ? DMA_DESC_CTRL_OAM :
						 DMA_DESC_CTRL) |
						((len + RTL_NI_DMA_HDR_LEN) <<
						 DMA_DESC_LEN_SHIFT));
	dma_wmb();
	dma->head = (dma->head + 1) & (RTL_NI_DMA_ENTRIES - 1);
	writel(dma->head, rtl_ni_dma_vp(dma) + DMA_VP_WRITE);
	writel(BIT(0), rtl_ni_dma_vp(dma) + DMA_VP_MISC_IRQ);
	return 0;
}

/* CU WiFi-NE backport: inject a downstream (LAN->Wi-Fi) frame into the NE
 * lookup path. Unlike rtl_ni_dma_xmit() there is no LSO prefix or software
 * Header A: the NE interface ID travels in the descriptor control word and
 * the skb payload is placed verbatim at the slot base. Ownership is taken
 * here (the caller is an nf_hook returning NF_STOLEN), matching the base
 * rtl_dma_tx_wifi() semantics. */
int rtl_ni_dma_xmit_wifi(struct rtl_ni_dma *dma, struct net_device *dev,
			 struct sk_buff *skb, unsigned int id)
{
	unsigned int offset, length = max(skb->len, DMA_MIN_FRAME);

	if (!id || id > RTL_WIFI_ID_MAX || skb->len < ETH_HLEN ||
	    length > RTL_NI_DMA_BUF_SIZE)
		return -EINVAL;
	if (skb_is_gso(skb) || skb_vlan_tag_present(skb) ||
	    skb->ip_summed == CHECKSUM_PARTIAL)
		return -EOPNOTSUPP;

	pr_emerg_ratelimited("WB_AC dmawifi begin id=%u len=%u head=%u tail=%u\n",
			     id, skb->len, dma->head, dma->tail);
	rtl_ni_dma_reclaim(dma);
	if (!rtl_ni_dma_avail(dma)) {
		pr_emerg_ratelimited("WB_AC dmawifi EBUSY head=%u tail=%u\n",
				     dma->head, dma->tail);
		return -EBUSY;
	}

	offset = rtl_ni_dma_buf_offset(dma->head);
	if (skb_copy_bits(skb, 0, dma->mem + offset, skb->len))
		return -EFAULT;
	memset(dma->mem + offset + skb->len, 0, length - skb->len);
	dma->desc[dma->head].addr = cpu_to_le32(dma->mem_dma + offset);
	dma->desc[dma->head].ctrl =
		cpu_to_le32(rtl_wifi_lookup_control(id, length));
	dma_wmb();
	dma->head = (dma->head + 1) & (RTL_NI_DMA_ENTRIES - 1);
	writel(dma->head, rtl_ni_dma_vp(dma) + DMA_VP_WRITE);
	writel(BIT(0), rtl_ni_dma_vp(dma) + DMA_VP_MISC_IRQ);
	pr_emerg_ratelimited("WB_AC dmawifi done id=%u head=%u\n", id, dma->head);
	DEV_STATS_INC(dev, tx_packets);
	DEV_STATS_ADD(dev, tx_bytes, skb->len);
	dev_consume_skb_any(skb);
	return 0;
}
