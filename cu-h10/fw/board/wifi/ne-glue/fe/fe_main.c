// SPDX-License-Identifier: GPL-2.0-or-later
#include <linux/bitfield.h>
#include <linux/bitmap.h>
#include <linux/debugfs.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/if_vlan.h>
#include <linux/io.h>
#include <linux/ip.h>
#include <linux/ppp_defs.h>
#include <linux/rhashtable.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/unaligned.h>
#include <net/flow_offload.h>
#include <net/pkt_cls.h>

#include "fe_priv.h"
#include "rtl9617c_itu.h"
/* CU WiFi-NE backport: RTL_WIFI_SOURCE / RTL_WIFI_ID_MAX. */
#include "../rtl9617c-wifi-format.h"

#define FE_CONTROL_ENABLE		BIT(10)
#define FE_CONTROL_FIELDS		(GENMASK(9, 4) | GENMASK(21, 16) | GENMASK(26, 24))
#define FE_CONTROL_INIT			(BIT(31) | BIT(12) | (32U << 4) | (16U << 16))
#define FE_CLASSIFIER_BASE		1024
#define FE_MAP_BASE			24
#define FE_MAP_SIDES			4
#define FE_LPB_SIDES			3
#define FE_MTU_MASK			GENMASK(13, 0)
#define FE_INTERFACE_INIT		(BIT(23) | BIT(18))
#define FE_INTERFACE_SMAC_SHIFT		19
#define FE_SMAC_VALID			BIT(16)
#define FE_FDB_FOUND			5
#define FE_FDB_LOOKUP			4
#define FE_FDB_ADD			0x45
#define FE_FDB_DELETE			0x85
#define FE_FDB_STATIC			(BIT(9) | BIT(19) | BIT(20) | BIT(21))
#define FE_FDB_INDEX			GENMASK(16, 4)
#define FE_REORDER_CTRL			0x80
#define FE_REORDER_USER			0x84
#define FE_REORDER_ATTR			0x88
#define FE_REORDER_ATTR2		0x8c
#define FE_REORDER_ID			0x90
#define FE_PPPOE_HLEN			8

static const unsigned int rtl_fe_saved_regs[] = {
	RTL_FE_BUCKET_CFG, RTL_FE_HASH_BASE_HIGH, RTL_FE_HASH_BASE_LOW,
	RTL_FE_ACTION_BASE_HIGH, RTL_FE_ACTION_BASE_LOW, RTL_FE_ACTION_SLOT_CFG,
	RTL_FE_OVERFLOW_BASE_HIGH, RTL_FE_OVERFLOW_BASE_LOW,
	RTL_FE_DEFAULT_SLOT_CFG, RTL_FE_DEFAULT_BASE_HIGH, RTL_FE_DEFAULT_BASE_LOW,
	RTL_FE_HASH_CFG, RTL_FE_KEY_MASK_0, RTL_FE_KEY_MASK_1, RTL_FE_HASH_ENABLE,
	RTL_FE_CACHE_CFG, RTL_FE_ACTION_GROUP_CFG,
	RTL_FE_LPB_CFG, RTL_FE_LPB_PROFILE,
	RTL_FE_LPB_TABLE(0, 0), RTL_FE_LPB_TABLE(0, 1), RTL_FE_LPB_TABLE(0, 2),
	RTL_FE_LPB_TABLE(1, 0), RTL_FE_LPB_TABLE(1, 1), RTL_FE_LPB_TABLE(1, 2),
	RTL_FE_HASH_MODE, RTL_FE_SWO_TUPLE,
	RTL_FE_KEY_PROFILE(1), RTL_FE_KEY_PROFILE(2), RTL_FE_KEY_PROFILE(3),
	RTL_FE_KEY_PROFILE(4), RTL_FE_KEY_PROFILE(5), RTL_FE_KEY_PROFILE(6),
	RTL_FE_KEY_PROFILE(7), RTL_FE_PARSER_CFG,
	RTL_FE_ACTION_GROUP(0), RTL_FE_ACTION_GROUP(1), RTL_FE_ACTION_GROUP(2),
	RTL_FE_ACTION_GROUP(3), RTL_FE_ACTION_GROUP(4),
	RTL_NI_L2TM_ES_CTRL, RTL_NI_L2TM_TABLE_0, RTL_NI_L2TM_TABLE_1,
	RTL_NI_NITX_CONTROL,
	RTL_FE_TPID0, RTL_FE_TPID1, RTL_FE_TPID2,
	RTL_FE_PPP_PROTOCOL0, RTL_FE_PPP_PROTOCOL1, RTL_FE_CONTROL,
	RTL_FE_MISS_TEMPLATE, RTL_FE_AXI_PATCH, RTL_FE_AXI_ID1_LIMIT,
	RTL_FE_AXI_OUTSTANDING,
	RTL_FE_PPP_CONFIG, RTL_FE_TABLE_CFG1, RTL_FE_TABLE_CFG0, RTL_FE_CAM_DATA_AUX,
};

static const unsigned int rtl_fe_bridge_masks[] = {
	RTL_FE_MASK_BRIDGE, RTL_FE_MASK_LEARN, RTL_FE_MASK_LEARN_PPPOE,
};

static const struct rhashtable_params rtl_fe_flow_params = {
	.head_offset = offsetof(struct rtl_fe_flow, node),
	.key_offset = offsetof(struct rtl_fe_flow, cookie),
	.key_len = sizeof(unsigned long),
	.automatic_shrinking = true,
};

struct rtl_fe_port *rtl_fe_port_find(struct rtl_fe *fe, struct net_device *netdev)
{
	struct rtl_fe_port *port;

	list_for_each_entry(port, &fe->ports, list)
		if (!port->retired && port->netdev == netdev)
			return port;
	return NULL;
}

/* ---- CU WiFi-NE backport: Wi-Fi peer identity helpers ----------------- */
static struct rtl_fe_wifi_peer *fe_wifi_peer(struct rtl_fe *fe,
					     struct rtl_fe_port *port,
					     const u8 *address)
{
	struct rtl_fe_wifi_peer *peer;

	list_for_each_entry(peer, &fe->wifi_peers, list)
		if (peer->port == port && ether_addr_equal(peer->address, address))
			return peer;
	return NULL;
}

static void fe_wifi_forget_port(struct rtl_fe *fe, struct rtl_fe_port *port)
{
	struct rtl_fe_wifi_peer *peer, *next;

	list_for_each_entry_safe(peer, next, &fe->wifi_peers, list)
		if (peer->port == port) {
			list_del(&peer->list);
			kfree(peer);
		}
}

static struct rtl_fe_flow *rtl_fe_flow_find(struct rtl_fe *fe, unsigned long cookie)
{
	return rhashtable_lookup_fast(&fe->cookies, &cookie, rtl_fe_flow_params);
}

static void rtl_fe_collect_ports(struct rtl_fe *fe)
{
	struct rtl_fe_port *port, *next;
	struct rtl_fe_flow *flow;

	list_for_each_entry_safe(port, next, &fe->ports, list) {
		bool owned = false;

		if (!port->retired || port->bindings)
			continue;
		list_for_each_entry(flow, &fe->flows, list) {
			if (flow->input == port || flow->output == port) {
				owned = true;
				break;
			}
		}
		if (!owned) {
			list_del(&port->list);
			kfree(port);
		}
	}
}

static int rtl_fe_map_read(struct rtl_fe *fe, unsigned int index, u32 *val)
{
	int ret;

	ret = rtl_fe_indirect(fe, RTL_NI_QM_PORT_MAP_CMD,
			      RTL_NI_INDIRECT_ACCESS | index);
	if (!ret)
		*val = rtl_fe_read(fe, RTL_NI_QM_PORT_MAP_DATA);
	return ret;
}

static int rtl_fe_map_write(struct rtl_fe *fe, unsigned int index, u32 val)
{
	rtl_fe_write(fe, RTL_NI_QM_PORT_MAP_DATA, val);
	return rtl_fe_indirect(fe, RTL_NI_QM_PORT_MAP_CMD, RTL_NI_INDIRECT_ACCESS |
			       RTL_NI_INDIRECT_WRITE | index);
}

static int rtl_fe_save(struct rtl_fe *fe)
{
	unsigned int i, side;
	int ret;

	for (i = 0; i < ARRAY_SIZE(rtl_fe_saved_regs); i++)
		fe->saved[i] = rtl_fe_read(fe, rtl_fe_saved_regs[i]);
	for (i = 0; i < FE_LAN_PORTS; i++)
		fe->lan_saved[i] = rtl_fe_read(fe, RTL_NI_LAN_RX_CTRL(i));
	fe->xge_saved = rtl_fe_read(fe, RTL_NI_XGE_BYPASS_CFG);

	ret = rtl_fe_mask_read(fe, RTL_FE_MASK_L3, fe->mask_saved);
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(rtl_fe_bridge_masks); i++) {
		ret = rtl_fe_mask_read(fe, rtl_fe_bridge_masks[i],
				       fe->bridge_mask_saved[i]);
		if (ret)
			return ret;
	}

	for (i = 0; i < FE_LPB_ENTRIES; i++) {
		ret = rtl_fe_classifier_read(fe, FE_CLASSIFIER_BASE + 4 * i,
					     fe->classifier_saved[i]);
		if (ret)
			return ret;
		for (side = 0; side < FE_MAP_SIDES; side++) {
			ret = rtl_fe_map_read(fe, (FE_MAP_BASE + i) | (side << 6),
					      &fe->map_saved[i][side]);
			if (ret)
				return ret;
		}
	}
	fe->prepared = true;
	return 0;
}

static int rtl_fe_setup_masks(struct rtl_fe *fe)
{
	u32 mask[RTL_FE_MASK_WORDS];
	int ret;

	rtl_fe_mask_l3(mask);
	mask[6] |= BIT(23) | BIT(26);
	mask[0] &= ~(BIT(1) | BIT(2) | BIT(3));
	mask[3] &= ~BIT(4);
	mask[2] &= ~(BIT(30) | BIT(31));
	mask[3] &= ~(BIT(2) | BIT(3));
	mask[2] &= ~(BIT(25) | BIT(27));
	ret = rtl_fe_mask_write(fe, RTL_FE_MASK_L3, mask);
	if (ret)
		return ret;

	rtl_fe_mask_bridge(mask);
	ret = rtl_fe_mask_write(fe, RTL_FE_MASK_BRIDGE, mask);
	if (ret)
		return ret;

	rtl_fe_mask_bridge(mask);
	rtl_fe_bits_set(mask, 92, 2, 0);
	rtl_fe_bits_set(mask, 96, 2, 0);
	ret = rtl_fe_mask_write(fe, RTL_FE_MASK_LEARN, mask);
	if (ret)
		return ret;

	rtl_fe_bits_set(mask, 135, 8, 255);
	rtl_fe_bits_set(mask, 88, 1, 0);
	return rtl_fe_mask_write(fe, RTL_FE_MASK_LEARN_PPPOE, mask);
}

static int rtl_fe_setup_lpb(struct rtl_fe *fe)
{
	u32 cls[RTL_FE_CLASSIFIER_WORDS], lpb[RTL_FE_LPB_WORDS];
	unsigned int i, side, source;
	int ret;

	for (i = 0; i < FE_LPB_ENTRIES; i++) {
		source = i ? FE_SOURCE_PON : 0;

		rtl_fe_classify_hash(cls, 0, source);
		if (!i)
			rtl_fe_bits_set(cls, 208, 1, 0);
		ret = rtl_fe_classifier_write(fe, FE_CLASSIFIER_BASE + 4 * !i, cls);
		if (ret)
			return ret;

		rtl_fe_ingress_lpb(lpb, source, 16);
		rtl_fe_bits_set(lpb, 42, 4, !i);
		for (side = 0; side < FE_LPB_SIDES; side++)
			rtl_fe_write(fe, RTL_FE_LPB_TABLE(i, side), lpb[side]);

		for (side = 0; side < FE_MAP_SIDES; side++) {
			ret = rtl_fe_map_write(fe, (i ? 24 : 25) | (side << 6),
					       i ? 12 : 13);
			if (ret)
				return ret;
		}
	}

	rtl_fe_rmw(fe, RTL_FE_LPB_CFG, BIT(0) | BIT(10), BIT(3) | BIT(2) | BIT(19));
	rtl_fe_write(fe, RTL_FE_LPB_PROFILE, 7 | (25 << 8) | (1 << 14) | (24 << 16) |
		     (2 << 22) | (3 << 24));
	return 0;
}

static int rtl_fe_prepare(struct rtl_fe *fe)
{
	static const u16 protocols[FE_CAM_PROTOCOLS] = {
		ETH_P_PPP_SES, PPP_IP, PPP_IPV6,
	};
	unsigned int i;
	int ret;

	ret = rtl_fe_save(fe);
	if (ret)
		return ret;

	rtl_fe_rmw(fe, RTL_FE_CAM_DATA_AUX, 0, RTL_FE_CAM_AUX_L4_CSUM);
	rtl_fe_rmw(fe, RTL_FE_CONTROL, FE_CONTROL_ENABLE, 0);
	rtl_fe_dma_tables(fe, lower_32_bits(fe->dma),
			  (upper_32_bits(fe->dma) & 0xff) | 2);
	ret = rtl_fe_indirect(fe, RTL_FE_SYNC_CMD, 1);
	if (ret)
		return ret;

	ret = rtl_fe_setup_masks(fe);
	if (ret)
		return ret;

	rtl_fe_write(fe, RTL_FE_PPP_PROTOCOL0, 0x11);
	rtl_fe_write(fe, RTL_FE_PPP_PROTOCOL1, PPP_IP | PPP_IPV6 << 16);
	rtl_fe_rmw(fe, RTL_FE_TABLE_CFG0, 0, BIT(31));
	rtl_fe_rmw(fe, RTL_FE_CONTROL, FE_CONTROL_FIELDS, FE_CONTROL_INIT);
	rtl_fe_rmw(fe, RTL_FE_PPP_CONFIG, 0, 0x1f00);
	rtl_fe_rmw(fe, RTL_FE_TABLE_CFG1, GENMASK(11, 0), 0xf21);

	ret = rtl_fe_setup_lpb(fe);
	if (ret)
		return ret;

	rtl_fe_rmw(fe, RTL_NI_L2TM_ES_CTRL, 0, BIT(12) | BIT(13));
	rtl_fe_write(fe, RTL_NI_PORT_TABLE_ENTRY(12), 0xff | (6 << 16));
	rtl_fe_write(fe, RTL_NI_PORT_TABLE_ENTRY(13), 0xff | (6 << 16));
	for (i = 0; i < 5; i++)
		rtl_fe_write(fe, RTL_FE_ACTION_GROUP(i), 0);
	rtl_fe_write(fe, RTL_FE_ACTION_GROUP_CFG, RTL_FE_ACTION_GROUPS | (3U << 25));
	rtl_fe_write(fe, RTL_FE_SWO_TUPLE, RTL_FE_MASK_L3);
	rtl_fe_write(fe, RTL_FE_KEY_PROFILE(1), RTL_FE_MASK_BRIDGE | (1 << 8));
	rtl_fe_write(fe, RTL_FE_KEY_PROFILE(2), RTL_FE_MASK_LEARN | (2 << 8));
	rtl_fe_write(fe, RTL_FE_KEY_PROFILE(3), RTL_FE_MASK_LEARN_PPPOE | (3 << 8));
	rtl_fe_write(fe, RTL_FE_HASH_MODE, 4);
	rtl_fe_write(fe, RTL_FE_PARSER_CFG, 0x020d0000);
	rtl_fe_write(fe, RTL_FE_TPID0, 0x88a88100);
	rtl_fe_write(fe, RTL_FE_TPID1, 0x92009100);
	rtl_fe_write(fe, RTL_FE_TPID2, 0x77);

	for (i = 0; i < FE_CAM_PROTOCOLS; i++) {
		ret = rtl_fe_cam_protocol_get(fe, &fe->protocol_cam[i], i ? 8 : 2,
					      protocols[i]);
		if (ret < 0)
			return ret;
		if (i)
			fe->ppp_protocol_ids[i - 1] = ret;
	}

	rtl_fe_rmw(fe, RTL_NI_NITX_CONTROL, 0, GENMASK(13, 0));
	rtl_fe_cache_start(fe);
	rtl_fe_rmw(fe, RTL_FE_CONTROL, 0, FE_CONTROL_ENABLE);
	return 0;
}

static int rtl_fe_restore(struct rtl_fe *fe)
{
	unsigned int i, side;
	int ret;

	if (!fe->prepared)
		return 0;

	rtl_fe_rmw(fe, RTL_FE_CONTROL, FE_CONTROL_ENABLE, 0);
	rtl_fe_write(fe, RTL_FE_HASH_ENABLE, 0);
	ret = rtl_fe_indirect(fe, RTL_FE_SYNC_CMD, 1);
	if (ret)
		return ret;

	for (i = 0; i < FE_CAM_PROTOCOLS; i++) {
		ret = rtl_fe_cam_protocol_put(fe, &fe->protocol_cam[i]);
		if (ret)
			return ret;
	}

	for (i = 0; i < FE_LPB_ENTRIES; i++) {
		for (side = 0; side < FE_MAP_SIDES; side++) {
			ret = rtl_fe_map_write(fe, (FE_MAP_BASE + i) | (side << 6),
					       fe->map_saved[i][side]);
			if (ret)
				return ret;
		}
		ret = rtl_fe_classifier_write(fe, FE_CLASSIFIER_BASE + 4 * i,
					      fe->classifier_saved[i]);
		if (ret)
			return ret;
	}

	ret = rtl_fe_mask_write(fe, RTL_FE_MASK_L3, fe->mask_saved);
	if (ret)
		return ret;
	for (i = 0; i < ARRAY_SIZE(rtl_fe_bridge_masks); i++) {
		ret = rtl_fe_mask_write(fe, rtl_fe_bridge_masks[i],
					fe->bridge_mask_saved[i]);
		if (ret)
			return ret;
	}

	for (i = 0; i < ARRAY_SIZE(rtl_fe_saved_regs); i++)
		rtl_fe_write(fe, rtl_fe_saved_regs[i], fe->saved[i]);
	for (i = 0; i < FE_LAN_PORTS; i++)
		rtl_fe_write(fe, RTL_NI_LAN_RX_CTRL(i), fe->lan_saved[i]);
	rtl_fe_write(fe, RTL_NI_XGE_BYPASS_CFG, fe->xge_saved);
	rtl_fe_read(fe, RTL_FE_HASH_BASE_LOW);
	fe->prepared = false;
	return 0;
}

static int rtl_fe_smac_get(struct rtl_fe *fe, const u8 *address,
			   unsigned int *index)
{
	u32 words[RTL_FE_SMAC_WORDS] = { };
	unsigned int i, byte;
	int ret;

	for (i = 0; i < FE_SOURCE_MACS; i++) {
		struct rtl_fe_mac *mac = &fe->source_macs[i];

		if (mac->users && ether_addr_equal(address, mac->address)) {
			mac->users++;
			*index = i;
			return 0;
		}
	}

	for (i = 0; i < FE_SOURCE_MACS; i++)
		if (!fe->source_macs[i].users)
			break;
	if (i == FE_SOURCE_MACS)
		return -ENOSPC;

	ret = rtl_fe_smac_read(fe, i, fe->source_macs[i].saved);
	if (ret)
		return ret;
	for (byte = 0; byte < ETH_ALEN; byte++)
		rtl_fe_bits_set(words, (ETH_ALEN - 1 - byte) * 8, 8, address[byte]);
	words[1] |= FE_SMAC_VALID;
	ret = rtl_fe_smac_write(fe, i, words);
	if (ret)
		return ret;

	ether_addr_copy(fe->source_macs[i].address, address);
	fe->source_macs[i].users = 1;
	*index = i;
	return 0;
}

static int rtl_fe_smac_put(struct rtl_fe *fe, unsigned int index)
{
	struct rtl_fe_mac *mac = &fe->source_macs[index];
	int ret;

	if (mac->users > 1) {
		mac->users--;
		return 0;
	}
	ret = rtl_fe_smac_write(fe, index, mac->saved);
	if (!ret)
		mac->users = 0;
	return ret;
}

static int rtl_fe_interface_get(struct rtl_fe *fe, struct rtl_fe_flow *flow)
{
	unsigned int index = find_first_zero_bit(fe->counters, FE_INTERFACES);
	struct rtl_fe_interface *intf;
	unsigned int i;
	int ret;

	if (index == FE_INTERFACES) {
		for (i = 0; i < FE_INTERFACES; i++) {
			intf = &fe->interfaces[i];
			if (intf->source_mac == flow->source_mac &&
			    intf->pppoe == flow->pppoe &&
			    (!intf->counted || index == FE_INTERFACES)) {
				index = i;
				if (!intf->counted)
					break;
			}
		}
		if (index == FE_INTERFACES)
			return -ENOSPC;
	}

	intf = &fe->interfaces[index];
	if (!intf->users) {
		ret = rtl_fe_indirect(fe, RTL_FE_INTERFACE_CMD,
				      RTL_NI_INDIRECT_ACCESS | index);
		if (ret)
			return ret;
		intf->saved = rtl_fe_read(fe, RTL_FE_INTERFACE_DATA);
		intf->source_mac = flow->source_mac;
		intf->pppoe = flow->pppoe;
		__set_bit(index, fe->counters);
	}

	flow->counter = index;
	flow->counted = index < FE_COUNTERS && !intf->counted;
	intf->counted |= flow->counted;
	intf->users++;
	flow->interface_owned = true;
	if (intf->users != 1)
		return 0;

	rtl_fe_write(fe, RTL_FE_INTERFACE_DATA, FE_INTERFACE_INIT |
		     ((flow->source_mac + 1) << FE_INTERFACE_SMAC_SHIFT) | flow->pppoe);
	return rtl_fe_indirect(fe, RTL_FE_INTERFACE_CMD, RTL_NI_INDIRECT_ACCESS |
			       RTL_NI_INDIRECT_WRITE | index);
}

static int rtl_fe_interface_put(struct rtl_fe *fe, struct rtl_fe_flow *flow)
{
	struct rtl_fe_interface *intf = &fe->interfaces[flow->counter];
	int ret;

	if (intf->users == 1) {
		rtl_fe_write(fe, RTL_FE_INTERFACE_DATA, intf->saved);
		ret = rtl_fe_indirect(fe, RTL_FE_INTERFACE_CMD,
				      RTL_NI_INDIRECT_ACCESS |
				      RTL_NI_INDIRECT_WRITE | flow->counter);
		if (ret)
			return ret;
		__clear_bit(flow->counter, fe->counters);
	}
	intf->users--;
	if (flow->counted)
		intf->counted = false;
	return 0;
}

static unsigned int rtl_fe_mtu_shift(unsigned int index)
{
	return (index % 2) * 16;
}

static int rtl_fe_mtu_get(struct rtl_fe *fe, struct rtl_fe_flow *flow,
			  unsigned int size)
{
	unsigned int i, index = FE_MTUS, shift;
	struct rtl_fe_mtu *mtu;
	u32 val;

	for (i = 0; i < FE_MTUS; i++) {
		if (fe->mtus[i].users && fe->mtus[i].size == size) {
			index = i;
			break;
		}
		if (!fe->mtus[i].users && index == FE_MTUS)
			index = i;
	}
	if (index == FE_MTUS)
		return -ENOSPC;

	mtu = &fe->mtus[index];
	if (!mtu->users) {
		shift = rtl_fe_mtu_shift(index);
		val = rtl_fe_read(fe, RTL_FE_MTU(index));
		mtu->saved = (val >> shift) & FE_MTU_MASK;
		mtu->size = size;
		rtl_fe_write(fe, RTL_FE_MTU(index),
			     (val & ~(FE_MTU_MASK << shift)) | size << shift);
	}
	mtu->users++;
	flow->mtu_index = index;
	flow->mtu_owned = true;
	return 0;
}

static void rtl_fe_mtu_put(struct rtl_fe *fe, struct rtl_fe_flow *flow)
{
	unsigned int index = flow->mtu_index, shift = rtl_fe_mtu_shift(index);
	struct rtl_fe_mtu *mtu = &fe->mtus[index];

	if (!--mtu->users)
		rtl_fe_rmw(fe, RTL_FE_MTU(index), FE_MTU_MASK << shift,
			   mtu->saved << shift);
	flow->mtu_owned = false;
}

static int rtl_fe_destination_get(struct rtl_fe *fe, struct rtl_fe_flow *flow,
				  const u8 *address)
{
	u32 words[RTL_FE_FDB_WORDS], result;
	struct rtl_fe_flow *other;
	int ret;

	ether_addr_copy(flow->destination, address);
	list_for_each_entry(other, &fe->flows, list) {
		if (other == flow || !other->destination_owned ||
		    !ether_addr_equal(other->destination, address))
			continue;
		flow->destination_index = other->destination_index;
		memcpy(flow->destination_saved, other->destination_saved,
		       sizeof(flow->destination_saved));
		flow->destination_created = other->destination_created;
		flow->destination_owned = true;
		return 0;
	}

	rtl_fe_fdb_key(words, address);
	ret = rtl_fe_fdb_command(fe, FE_FDB_LOOKUP, words, &result);
	if (ret)
		return ret;
	flow->destination_created = (result & 15) != FE_FDB_FOUND;
	if (!flow->destination_created)
		memcpy(flow->destination_saved, words, sizeof(words));

	if (flow->destination_created)
		rtl_fe_fdb_key(words, address);
	else
		words[0] |= FE_FDB_STATIC;
	ret = rtl_fe_fdb_command(fe, FE_FDB_ADD, words, &result);
	if (ret)
		return ret;
	if ((result & 15) != FE_FDB_FOUND)
		return -ENOSPC;
	flow->destination_owned = true;

	rtl_fe_fdb_key(words, address);
	ret = rtl_fe_fdb_command(fe, FE_FDB_LOOKUP, words, &result);
	if (ret)
		return ret;
	if ((result & 15) != FE_FDB_FOUND)
		return -EIO;
	flow->destination_index = FIELD_GET(FE_FDB_INDEX, result);
	return 0;
}

static int rtl_fe_destination_put(struct rtl_fe *fe, struct rtl_fe_flow *flow)
{
	u32 words[RTL_FE_FDB_WORDS], result;
	struct rtl_fe_flow *other;

	list_for_each_entry(other, &fe->flows, list)
		if (other != flow && other->destination_owned &&
		    ether_addr_equal(other->destination, flow->destination))
			return 0;

	if (flow->destination_created) {
		rtl_fe_fdb_key(words, flow->destination);
		return rtl_fe_fdb_command(fe, FE_FDB_DELETE, words, &result);
	}
	memcpy(words, flow->destination_saved, sizeof(words));
	return rtl_fe_fdb_command(fe, FE_FDB_ADD, words, &result);
}

int rtl_fe_vlan_tpid(__be16 protocol)
{
	switch (ntohs(protocol)) {
	case ETH_P_8021Q:
		return 1;
	case ETH_P_8021AD:
		return 2;
	default:
		return -EOPNOTSUPP;
	}
}

static int rtl_fe_vlan_match(const struct flow_match_vlan *match,
			     struct rtl_fe_vlan *vlan)
{
	int tpid;

	if (match->mask->vlan_id != VLAN_VID_MASK ||
	    match->mask->vlan_tpid != htons(0xffff) ||
	    match->mask->vlan_priority || match->mask->vlan_dei)
		return -EOPNOTSUPP;
	tpid = rtl_fe_vlan_tpid(match->key->vlan_tpid);
	if (tpid < 0)
		return tpid;
	*vlan = (struct rtl_fe_vlan){ .vid = match->key->vlan_id, .tpid = tpid };
	return 0;
}

static int rtl_fe_parse_vlans(struct flow_rule *rule, struct rtl_fe_rule *data)
{
	struct flow_match_vlan vlan;
	int ret;

	data->vlan_count = 0;
	if (flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_VLAN)) {
		flow_rule_match_vlan(rule, &vlan);
		ret = rtl_fe_vlan_match(&vlan, &data->vlan[data->vlan_count++]);
		if (ret)
			return ret;
	}
	if (flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_CVLAN)) {
		if (!data->vlan_count)
			return -EOPNOTSUPP;
		flow_rule_match_cvlan(rule, &vlan);
		ret = rtl_fe_vlan_match(&vlan, &data->vlan[data->vlan_count++]);
		if (ret)
			return ret;
	}
	return 0;
}

struct rtl_fe_vlan_edit {
	struct rtl_fe_vlan vlan[2];
	bool known[2];
	unsigned int count;
	bool changed;
};

static int rtl_fe_vlan_edit(struct rtl_fe_vlan_edit *edit,
			    const struct flow_action_entry *act)
{
	int tpid;

	if (act->id == FLOW_ACTION_VLAN_POP) {
		if (!edit->count)
			return -EOPNOTSUPP;
		edit->vlan[0] = edit->vlan[1];
		edit->known[0] = edit->known[1];
		edit->count--;
		edit->changed = true;
		return 0;
	}

	if (edit->count == 2 || act->vlan.vid > VLAN_VID_MASK || act->vlan.prio > 7)
		return -EOPNOTSUPP;
	tpid = rtl_fe_vlan_tpid(act->vlan.proto);
	if (tpid < 0)
		return tpid;
	edit->vlan[1] = edit->vlan[0];
	edit->known[1] = edit->known[0];
	edit->vlan[0] = (struct rtl_fe_vlan){
		.vid = act->vlan.vid,
		.tpid = tpid,
		.priority = act->vlan.prio,
	};
	edit->known[0] = true;
	edit->count++;
	edit->changed = true;
	return 0;
}

static int rtl_fe_vlan_edit_done(const struct rtl_fe_vlan_edit *edit)
{
	unsigned int i;

	if (!edit->changed)
		return 0;
	for (i = 0; i < edit->count; i++)
		if (!edit->known[i])
			return -EOPNOTSUPP;
	return 0;
}

static int rtl_fe_parse_l3(struct rtl_fe_port *port, struct flow_rule *rule,
			   struct rtl_fe_rule *data)
{
	struct rtl_fe_vlan_edit edit = { };
	struct flow_match_ipv4_addrs addrs = { };
	struct flow_match_ipv6_addrs addrs6;
	struct flow_match_ports ports;
	struct flow_match_basic basic;
	struct flow_match_meta meta;
	struct flow_action_entry *act;
	struct net_device *output = NULL;
	u8 eth[ETH_HLEN] = { };
	__be32 new_source = 0, new_destination = 0;
	__be16 new_sport, new_dport, protocol;
	bool source_changed, destination_changed;
	int i, ret;

	if (!flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_META) ||
	    !flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_BASIC) ||
	    (!flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_IPV4_ADDRS) &&
	     !flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_IPV6_ADDRS)) ||
	    !flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_PORTS))
		return -EOPNOTSUPP;

	flow_rule_match_meta(rule, &meta);
	if (meta.key->ingress_ifindex != port->netdev->ifindex)
		return -EOPNOTSUPP;

	flow_rule_match_basic(rule, &basic);
	protocol = basic.key->n_proto;
	if (protocol == htons(ETH_P_PPP_SES)) {
		struct flow_match_pppoe pppoe;

		if (!flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_PPPOE))
			return -EOPNOTSUPP;
		flow_rule_match_pppoe(rule, &pppoe);
		if (pppoe.mask->session_id != htons(0xffff) ||
		    pppoe.mask->ppp_proto != htons(0xffff) ||
		    pppoe.mask->type != htons(0xffff) ||
		    pppoe.key->type != htons(ETH_P_PPP_SES))
			return -EOPNOTSUPP;
		if (pppoe.key->ppp_proto == htons(PPP_IP))
			protocol = htons(ETH_P_IP);
		else if (pppoe.key->ppp_proto == htons(PPP_IPV6))
			protocol = htons(ETH_P_IPV6);
		else
			return -EOPNOTSUPP;
		data->pppoe_input = true;
		data->pppoe_session = ntohs(pppoe.key->session_id);
	}

	data->kind = protocol == htons(ETH_P_IPV6) ? RTL_FE_RULE_IPV6 :
						     RTL_FE_RULE_IPV4;
	if ((protocol != htons(ETH_P_IP) && data->kind != RTL_FE_RULE_IPV6) ||
	    basic.mask->n_proto != htons(0xffff) || basic.mask->ip_proto != 0xff ||
	    (basic.key->ip_proto != IPPROTO_TCP && basic.key->ip_proto != IPPROTO_UDP))
		return -EOPNOTSUPP;
	if (flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_ENC_CONTROL))
		return -EOPNOTSUPP;

	ret = rtl_fe_parse_vlans(rule, data);
	if (ret)
		return ret;
	edit.count = data->vlan_count;
	memcpy(edit.vlan, data->vlan, sizeof(edit.vlan));

	flow_rule_match_ports(rule, &ports);
	if (ports.mask->src != htons(0xffff) || ports.mask->dst != htons(0xffff))
		return -EOPNOTSUPP;

	data->input = port;
	data->key = (struct rtl_fe_key){
		.source_port = ntohs(ports.key->src),
		.destination_port = ntohs(ports.key->dst),
		.protocol = basic.key->ip_proto,
		.ingress = port->source,
		.llid = port->llid,
		.mask = RTL_FE_MASK_L3,
	};

	if (data->kind == RTL_FE_RULE_IPV6) {
		if (!flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_IPV6_ADDRS))
			return -EOPNOTSUPP;
		flow_rule_match_ipv6_addrs(rule, &addrs6);
		for (i = 0; i < 4; i++) {
			if (addrs6.mask->src.s6_addr32[i] != htonl(~0U) ||
			    addrs6.mask->dst.s6_addr32[i] != htonl(~0U))
				return -EOPNOTSUPP;
			data->key.source[i] = ntohl(addrs6.key->src.s6_addr32[i]);
			data->key.destination[i] = ntohl(addrs6.key->dst.s6_addr32[i]);
		}
	} else {
		if (!flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_IPV4_ADDRS))
			return -EOPNOTSUPP;
		flow_rule_match_ipv4_addrs(rule, &addrs);
		if (addrs.mask->src != htonl(~0U) || addrs.mask->dst != htonl(~0U))
			return -EOPNOTSUPP;
		data->key.source[3] = ntohl(addrs.key->src);
		data->key.destination[3] = ntohl(addrs.key->dst);
		new_source = addrs.key->src;
		new_destination = addrs.key->dst;
	}

	new_sport = ports.key->src;
	new_dport = ports.key->dst;
	flow_action_for_each(i, act, &rule->action) {
		unsigned int offset = act->mangle.offset;
		u32 val;

		switch (act->id) {
		case FLOW_ACTION_PPPOE_PUSH:
			if (!act->pppoe.sid || !act->pppoe.mtu ||
			    act->pppoe.mtu > FE_MTU_MASK)
				return -EOPNOTSUPP;
			data->egress_pppoe = 3U | ((unsigned int)act->pppoe.sid << 2);
			data->mtu = act->pppoe.mtu;
			break;
		case FLOW_ACTION_VLAN_POP:
		case FLOW_ACTION_VLAN_PUSH:
			ret = rtl_fe_vlan_edit(&edit, act);
			if (ret)
				return ret;
			break;
		case FLOW_ACTION_REDIRECT:
			output = act->dev;
			break;
		case FLOW_ACTION_CSUM:
			break;
		case FLOW_ACTION_MANGLE:
			switch (act->mangle.htype) {
			case FLOW_ACT_MANGLE_HDR_TYPE_ETH:
				if (offset > ETH_HLEN - sizeof(val))
					return -EOPNOTSUPP;
				val = get_unaligned((u32 *)(eth + offset));
				put_unaligned((val & act->mangle.mask) | act->mangle.val,
					      (u32 *)(eth + offset));
				break;
			case FLOW_ACT_MANGLE_HDR_TYPE_IP4:
				if (data->kind == RTL_FE_RULE_IPV6 || act->mangle.mask)
					return -EOPNOTSUPP;
				if (offset == offsetof(struct iphdr, saddr))
					memcpy(&new_source, &act->mangle.val, 4);
				else if (offset == offsetof(struct iphdr, daddr))
					memcpy(&new_destination, &act->mangle.val, 4);
				else
					return -EOPNOTSUPP;
				break;
			case FLOW_ACT_MANGLE_HDR_TYPE_TCP:
			case FLOW_ACT_MANGLE_HDR_TYPE_UDP: {
				__be16 pair[2] = { new_sport, new_dport };

				if (offset)
					return -EOPNOTSUPP;
				memcpy(&val, pair, 4);
				val = (val & act->mangle.mask) | act->mangle.val;
				memcpy(pair, &val, 4);
				new_sport = pair[0];
				new_dport = pair[1];
				if (data->kind == RTL_FE_RULE_IPV6 &&
				    (new_sport != ports.key->src ||
				     new_dport != ports.key->dst))
					return -EOPNOTSUPP;
				break;
			}
			default:
				return -EOPNOTSUPP;
			}
			break;
		default:
			return -EOPNOTSUPP;
		}
	}

	data->output = rtl_fe_port_find(port->fe, output);
	if (!data->output || data->input == data->output)
		return -EOPNOTSUPP;
	ether_addr_copy(data->destination, eth);
	ether_addr_copy(data->source, eth + ETH_ALEN);
	if (!is_valid_ether_addr(data->source) ||
	    !is_valid_ether_addr(data->destination))
		return -EINVAL;

	source_changed = data->kind != RTL_FE_RULE_IPV6 &&
			 (new_source != addrs.key->src || new_sport != ports.key->src);
	destination_changed = data->kind != RTL_FE_RULE_IPV6 &&
			      (new_destination != addrs.key->dst ||
			       new_dport != ports.key->dst);
	if (source_changed && destination_changed)
		return -EOPNOTSUPP;
	ret = rtl_fe_vlan_edit_done(&edit);
	if (ret)
		return ret;

	data->action = (struct rtl_fe_action){
		.destination = data->output->destination,
		.check_mask = RTL_FE_MASK_L3,
		.deep_queue = data->output->destination >= FE_DEEPQ_DEST,
		.translate = source_changed || destination_changed,
		.translate_destination = destination_changed,
		.address = ntohl(destination_changed ? new_destination : new_source),
		.port = ntohs(destination_changed ? new_dport : new_sport),
		.vlan_set = edit.changed,
		.pppoe_pop = data->pppoe_input && !data->egress_pppoe,
		.vlan_count = edit.count,
	};
	memcpy(data->action.vlan, edit.vlan, sizeof(edit.vlan));
	data->ethernet_bytes = ETH_HLEN + VLAN_HLEN * edit.count +
			       (data->egress_pppoe ? FE_PPPOE_HLEN : 0);
	return 0;
}

static int rtl_fe_parse(struct rtl_fe_port *port, struct flow_cls_offload *cls,
			struct rtl_fe_rule *data)
{
	struct flow_rule *rule = flow_cls_offload_flow_rule(cls);
	int ret;

	ret = rtl_fe_parse_l3(port, rule, data);
	if (ret)
		return ret;
	return rtl_fe_itu_rule(data);
}

int rtl_fe_delete(struct rtl_fe *fe, struct rtl_fe_flow *flow)
{
	int ret;

	flow->deleting = true;
	if (flow->published) {
		ret = rtl_fe_age_write(fe, flow->hash_index, 0);
		if (ret)
			goto retry;
		ret = rtl_fe_cache_command(fe, flow->hash_index, flow->crc16, 1);
		if (ret)
			goto retry;
		flow->published = false;
	}
	((__le32 *)fe->memory)[flow->hash_index] = 0;
	dma_wmb();

	if (flow->destination_owned) {
		ret = rtl_fe_destination_put(fe, flow);
		if (ret)
			goto retry;
		flow->destination_owned = false;
	}
	if (flow->source_owned) {
		ret = rtl_fe_smac_put(fe, flow->source_mac);
		if (ret)
			goto retry;
		flow->source_owned = false;
	}
	if (flow->interface_owned) {
		ret = rtl_fe_interface_put(fe, flow);
		if (ret)
			goto retry;
		flow->interface_owned = false;
	}
	if (flow->mtu_owned)
		rtl_fe_mtu_put(fe, flow);

	__clear_bit(flow->hash_index, fe->hashes);
	if (flow->learned)
		rtl_fe_bridge_flow_removed(fe);
	if (flow->hashed)
		rhashtable_remove_fast(&fe->cookies, &flow->node, rtl_fe_flow_params);
	list_del(&flow->list);
	if (flow->installed)
		fe->deletes++;
	kfree(flow);
	return 0;

retry:
	mod_delayed_work(system_wq, &fe->cleanup_work, HZ);
	return ret;
}

static void rtl_fe_cleanup_work(struct work_struct *work)
{
	struct rtl_fe *fe = container_of(to_delayed_work(work), struct rtl_fe,
					 cleanup_work);
	struct rtl_fe_flow *flow, *next;

	mutex_lock(&fe->lock);
	list_for_each_entry_safe(flow, next, &fe->flows, list)
		if (flow->deleting)
			rtl_fe_delete(fe, flow);
	rtl_fe_collect_ports(fe);
	mutex_unlock(&fe->lock);
}

static void rtl_fe_rule_key(const struct rtl_fe_rule *data,
			    u32 words[RTL_FE_KEY_WORDS])
{
	unsigned int i;

	if (data->kind == RTL_FE_RULE_BRIDGE)
		rtl_fe_key_bridge(words, data->source, data->destination,
				  data->ethernet_protocol, &data->key);
	else
		rtl_fe_key_ip(words, &data->key, data->kind == RTL_FE_RULE_IPV6);
	rtl_fe_key_vlan(words, data->vlan, data->vlan_count);

	if (data->vlan_exact) {
		for (i = 0; i < data->vlan_count; i++) {
			rtl_fe_key_set(words, i ? RTL_FE_KEY_INNER_DEI : RTL_FE_KEY_TOP_DEI,
				       !!(data->ingress_tci[i] & VLAN_CFI_MASK));
			rtl_fe_key_set(words, i ? RTL_FE_KEY_INNER_PCP : RTL_FE_KEY_TOP_PCP,
				       data->ingress_tci[i] >> VLAN_PRIO_SHIFT);
		}
	}
	rtl_fe_key_set(words, RTL_FE_KEY_PPPOE_SESSION, data->pppoe_session);
	rtl_fe_key_set(words, RTL_FE_KEY_PPPOE_TYPE, data->pppoe_input ? 2 : 0);
	if (data->vlan_exact && data->pppoe_input)
		rtl_fe_key_set(words, RTL_FE_KEY_PPP_PROTOCOL, data->ppp_protocol_slot);
	rtl_fe_key_set(words, RTL_FE_KEY_ORIG_LSPID, 0);
	rtl_fe_key_set(words, RTL_FE_KEY_CTRL_SET_ID, 0);
	rtl_fe_key_set(words, RTL_FE_KEY_TABLE_ID, 0);
}

static bool rtl_fe_port_ready(const struct rtl_fe_port *port)
{
	return !port->retired && port->bindings && tc_can_offload(port->netdev) &&
	       (port->source != FE_SOURCE_PON || port->fe->pon_attached);
}

int rtl_fe_install(struct rtl_fe_port *port, struct rtl_fe_rule *data,
		   unsigned long cookie, struct rtl_fe_flow **out)
{
	u32 words[RTL_FE_KEY_WORDS], action[RTL_FE_ACTION_WORDS];
	u32 counters[RTL_FE_COUNTER_WORDS], crc32;
	struct rtl_fe *fe = port->fe;
	struct rtl_fe_flow *flow;
	unsigned int index, start;
	u16 crc16;
	int ret;

	if (port->retired)
		return -ENODEV;
	if (!rtl_fe_port_ready(data->input) || !rtl_fe_port_ready(data->output))
		return -EOPNOTSUPP;
	if (!fe->enabled || !netif_running(data->input->netdev) ||
	    !netif_running(data->output->netdev) ||
	    !netif_carrier_ok(data->input->netdev) ||
	    !netif_carrier_ok(data->output->netdev))
		return -EAGAIN;
	if (cookie && rtl_fe_flow_find(fe, cookie))
		return -EEXIST;

	rtl_fe_rule_key(data, words);
	rtl_fe_key_crc(words, &crc32, &crc16);
	start = rtl_fe_hash_bucket(crc16);
	for (index = start; index < start + RTL_FE_HASH_BUCKET; index++)
		if (!test_bit(index, fe->hashes))
			break;
	if (index == start + RTL_FE_HASH_BUCKET)
		return -ENOSPC;

	flow = kzalloc(sizeof(*flow), GFP_KERNEL);
	if (!flow)
		return -ENOMEM;
	flow->cookie = cookie ?: (unsigned long)flow;
	flow->hash_index = index;
	flow->crc16 = crc16;
	flow->kind = data->kind;
	flow->input = data->input;
	flow->output = data->output;
	flow->lastused = jiffies;
	flow->ethernet_bytes = data->ethernet_bytes;
	flow->pppoe = data->egress_pppoe;
	flow->ingress_session = data->pppoe_session;
	flow->ethernet_protocol = data->ethernet_protocol;
	ether_addr_copy(flow->ethernet_source, data->source);

	__set_bit(index, fe->hashes);
	ret = rhashtable_insert_fast(&fe->cookies, &flow->node, rtl_fe_flow_params);
	if (ret) {
		__clear_bit(index, fe->hashes);
		kfree(flow);
		return ret;
	}
	flow->hashed = true;
	list_add_tail(&flow->list, &fe->flows);

	if (data->kind != RTL_FE_RULE_BRIDGE) {
		ret = rtl_fe_smac_get(fe, data->source, &flow->source_mac);
		if (ret)
			goto rollback;
		flow->source_owned = true;
		ret = rtl_fe_destination_get(fe, flow, data->destination);
		if (ret)
			goto rollback;
		ret = rtl_fe_interface_get(fe, flow);
		if (ret)
			goto rollback;
	} else {
		ether_addr_copy(flow->destination, data->destination);
	}

	if (data->mtu) {
		ret = rtl_fe_mtu_get(fe, flow, data->mtu);
		if (ret)
			goto rollback;
		data->action.mtu_set = 1;
		data->action.mtu_index = flow->mtu_index;
	}

	if (flow->counted) {
		ret = rtl_fe_counter_read(fe, flow->counter, counters);
		if (ret)
			goto rollback;
		flow->bytes = (u64)counters[1] << 32 | counters[0];
		flow->packets = counters[2] + counters[3];
	}

	data->action.mac_da_index = flow->destination_index;
	data->action.egress_interface = flow->counter;
	rtl_fe_action_build(action, &data->action);
	rtl_fe_action_set(action, RTL_FE_L3_IF_COUNTER_EN, flow->counted);
	((__le32 *)fe->memory)[index] = cpu_to_le32(crc32);
	memcpy(fe->memory + RTL_FE_ACTION_OFFSET + index * RTL_FE_ACTION_BYTES,
	       action, sizeof(action));
	dma_wmb();
	flow->published = true;
	ret = rtl_fe_age_write(fe, index, 1);
	if (ret)
		goto rollback;

	flow->installed = true;
	fe->installs++;
	if (out)
		*out = flow;
	return 0;

rollback:
	if (rtl_fe_delete(fe, flow))
		fe->error = ret;
	return ret;
}

static int rtl_fe_replace(struct rtl_fe_port *port, struct flow_cls_offload *cls)
{
	struct rtl_fe_rule data = { };
	int ret;

	ret = rtl_fe_parse(port, cls, &data);
	if (ret)
		return ret;
	return rtl_fe_install(port, &data, cls->cookie, NULL);
}

static int rtl_fe_stats(struct rtl_fe *fe, struct rtl_fe_flow *flow,
			struct flow_cls_offload *cls)
{
	u32 words[RTL_FE_COUNTER_WORDS], packets, packet_delta;
	unsigned int age;
	u64 bytes, byte_delta;
	int ret;

	if (!flow->published)
		return -ENOENT;

	ret = rtl_fe_age_read(fe, flow->hash_index, &age);
	if (ret)
		return ret;
	if (age > 1) {
		ret = rtl_fe_age_write(fe, flow->hash_index, 1);
		if (ret)
			return ret;
		flow->lastused = jiffies;
	}

	if (!flow->counted) {
		flow_stats_update(&cls->stats, 0, 0, 0, flow->lastused,
				  FLOW_ACTION_HW_STATS_DELAYED);
		return 0;
	}

	ret = rtl_fe_counter_read(fe, flow->counter, words);
	if (ret)
		return ret;
	bytes = (u64)words[1] << 32 | words[0];
	packets = words[2] + words[3];
	if (bytes != flow->bytes || packets != flow->packets)
		flow->lastused = jiffies;
	byte_delta = bytes - flow->bytes;
	packet_delta = packets - flow->packets;
	flow_stats_update(&cls->stats,
			  byte_delta - (u64)packet_delta * flow->ethernet_bytes,
			  packet_delta, 0, flow->lastused,
			  FLOW_ACTION_HW_STATS_DELAYED);
	flow->bytes = bytes;
	flow->packets = packets;
	return 0;
}

static int rtl_fe_block_cb(enum tc_setup_type type, void *type_data, void *priv)
{
	struct flow_cls_offload *cls = type_data;
	struct rtl_fe_port *port = priv;
	struct rtl_fe *fe = port->fe;
	struct rtl_fe_flow *flow, *next;
	int ret;

	if (type != TC_SETUP_CLSFLOWER || cls->common.chain_index)
		return -EOPNOTSUPP;

	mutex_lock(&fe->lock);
	list_for_each_entry_safe(flow, next, &fe->flows, list) {
		if (flow->installed && !flow->deleting)
			continue;
		ret = rtl_fe_delete(fe, flow);
		if (ret)
			goto unlock;
	}

	flow = rtl_fe_flow_find(fe, cls->cookie);
	switch (cls->command) {
	case FLOW_CLS_REPLACE:
		ret = rtl_fe_replace(port, cls);
		break;
	case FLOW_CLS_DESTROY:
		ret = flow && flow->input == port ? rtl_fe_delete(fe, flow) : -ENOENT;
		break;
	case FLOW_CLS_STATS:
		ret = flow && flow->input == port ? rtl_fe_stats(fe, flow, cls) : -ENOENT;
		break;
	default:
		ret = -EOPNOTSUPP;
		break;
	}
	if (ret && ret != -EOPNOTSUPP && ret != -ENOENT && ret != -EEXIST)
		fe->misses++;
	rtl_fe_collect_ports(fe);
unlock:
	mutex_unlock(&fe->lock);
	return ret;
}

static int rtl_fe_flush_locked(struct rtl_fe *fe, struct rtl_fe_port *port)
{
	struct rtl_fe_flow *flow, *next;
	int ret;

	/* CU WiFi-NE backport: retire learned Wi-Fi peers for this port. */
	if (port)
		fe_wifi_forget_port(fe, port);
	list_for_each_entry_safe(flow, next, &fe->flows, list) {
		if (flow->input != port && flow->output != port)
			continue;
		ret = rtl_fe_delete(fe, flow);
		if (ret)
			return ret;
	}
	return 0;
}

static void rtl_fe_block_release(void *priv)
{
	struct rtl_fe_port *port = priv;
	struct rtl_fe *fe = port->fe;
	int ret;

	mutex_lock(&fe->lock);
	port->bindings--;
	WRITE_ONCE(fe->bindings, fe->bindings - 1);
	if (!port->bindings) {
		ret = rtl_fe_flush_locked(fe, port);
		if (ret)
			fe->error = ret;
	}
	rtl_fe_collect_ports(fe);
	mutex_unlock(&fe->lock);
}

int rtl_fe_setup_tc(struct rtl_fe *fe, struct net_device *netdev,
		    enum tc_setup_type type, void *data)
{
	struct flow_block_offload *block = data;
	struct rtl_fe_port *port, *candidate;
	struct flow_block_cb *cb;
	int ret = 0;

	if (!fe || type != TC_SETUP_FT)
		return -EOPNOTSUPP;
	if (block->binder_type != FLOW_BLOCK_BINDER_TYPE_CLSACT_INGRESS)
		return -EOPNOTSUPP;

	mutex_lock(&fe->lock);
	port = rtl_fe_port_find(fe, netdev);
	if (!port && block->command == FLOW_BLOCK_UNBIND) {
		list_for_each_entry(candidate, &fe->ports, list) {
			if (candidate->retired && candidate->netdev == netdev) {
				port = candidate;
				break;
			}
		}
	}
	if (!port) {
		ret = -ENODEV;
		goto unlock;
	}

	block->driver_block_list = &fe->blocks;
	cb = flow_block_cb_lookup(block->block, rtl_fe_block_cb, port);
	switch (block->command) {
	case FLOW_BLOCK_BIND:
		if (cb) {
			flow_block_cb_incref(cb);
			break;
		}
		if (!tc_can_offload(netdev)) {
			ret = -EOPNOTSUPP;
			break;
		}
		cb = flow_block_cb_alloc(rtl_fe_block_cb, port, port,
					 rtl_fe_block_release);
		if (IS_ERR(cb)) {
			ret = PTR_ERR(cb);
			break;
		}
		flow_block_cb_incref(cb);
		flow_block_cb_add(cb, block);
		list_add_tail(&cb->driver_list, &fe->blocks);
		port->bindings++;
		WRITE_ONCE(fe->bindings, fe->bindings + 1);
		break;
	case FLOW_BLOCK_UNBIND:
		if (!cb) {
			ret = -ENOENT;
			break;
		}
		if (!flow_block_cb_decref(cb)) {
			flow_block_cb_remove(cb, block);
			list_del(&cb->driver_list);
		}
		break;
	default:
		ret = -EOPNOTSUPP;
		break;
	}
unlock:
	mutex_unlock(&fe->lock);
	return ret;
}

int rtl_fe_add_port(struct rtl_fe *fe, struct net_device *netdev,
		    unsigned int source, unsigned int destination,
		    unsigned int llid)
{
	struct rtl_fe_port *port;

	if (!fe)
		return 0;

	port = kzalloc(sizeof(*port), GFP_KERNEL);
	if (!port)
		return -ENOMEM;
	port->fe = fe;
	port->netdev = netdev;
	port->source = source;
	port->destination = destination;
	port->llid = llid;

	mutex_lock(&fe->lock);
	list_add_tail(&port->list, &fe->ports);
	netdev->hw_features |= NETIF_F_HW_TC;
	netdev->features |= NETIF_F_HW_TC;
	mutex_unlock(&fe->lock);
	return 0;
}

/* ---- CU WiFi-NE backport: NE Wi-Fi interface -------------------------- */
int rtl_fe_add_wifi_port(struct rtl_fe *fe, struct net_device *netdev,
			 unsigned int id)
{
	struct rtl_fe_port *port;
	int ret;

	mutex_lock(&fe->lock);
	port = rtl_fe_port_find(fe, netdev);
	/* Wi-Fi DMA puts its interface ID in both POL_ID and metadata low8. */
	if (port) {
		port->wifi_id = id;
		port->llid = id;
		mutex_unlock(&fe->lock);
		return 0;
	}
	mutex_unlock(&fe->lock);
	ret = rtl_fe_add_port(fe, netdev, RTL_WIFI_SOURCE, 16, id);
	if (ret)
		return ret;
	mutex_lock(&fe->lock);
	port = rtl_fe_port_find(fe, netdev);
	if (port)
		port->wifi_id = id;
	mutex_unlock(&fe->lock);
	return 0;
}

bool rtl_fe_wifi_enabled(struct rtl_fe *fe)
{
	return fe && READ_ONCE(fe->enabled);
}

int rtl_fe_wifi_peer_route(struct rtl_fe *fe, struct net_device *netdev,
			   const u8 *address, unsigned int destination)
{
	struct rtl_fe_port *port;
	struct rtl_fe_wifi_peer *peer;
	struct rtl_fe_flow *flow;
	int ret = 0;

	mutex_lock(&fe->lock);
	port = rtl_fe_port_find(fe, netdev);
	if (!port || !port->wifi_id) {
		ret = -ENODEV;
		goto unlock;
	}
	peer = fe_wifi_peer(fe, port, address);
	if (destination && !peer) {
		peer = kzalloc(sizeof(*peer), GFP_KERNEL);
		if (!peer) {
			ret = -ENOMEM;
			goto unlock;
		}
		peer->port = port;
		ether_addr_copy(peer->address, address);
		list_add_tail(&peer->list, &fe->wifi_peers);
	}
	if (destination)
		peer->destination = destination;
	/* Refresh the MCGID (output destination) of live flows for this STA.
	 * Withdraw both lookup locations before changing an in-flight flow. */
	list_for_each_entry(flow, &fe->flows, list) {
		u32 *action;

		if (!flow->installed || flow->deleting || flow->output != port ||
		    !ether_addr_equal(flow->destination, address))
			continue;
		ret = rtl_fe_age_write(fe, flow->hash_index, 0);
		if (ret)
			goto unlock;
		ret = rtl_fe_cache_command(fe, flow->hash_index, flow->crc16, 1);
		if (ret)
			goto unlock;
		action = fe->memory + RTL_FE_ACTION_OFFSET +
			 flow->hash_index * RTL_FE_ACTION_BYTES;
		rtl_fe_action_set(action, RTL_FE_MCGID,
				  destination ? destination : port->destination);
		dma_wmb();
		ret = rtl_fe_age_write(fe, flow->hash_index, 1);
		if (ret)
			goto unlock;
	}
	if (!destination && peer) {
		list_del(&peer->list);
		kfree(peer);
	}
unlock:
	mutex_unlock(&fe->lock);
	return ret;
}

void rtl_fe_remove_port(struct rtl_fe *fe, struct net_device *netdev)
{
	struct rtl_fe_port *port;
	struct rtl_fe_flow *flow, *next;
	int ret;

	if (!fe)
		return;

	mutex_lock(&fe->lock);
	port = rtl_fe_port_find(fe, netdev);
	if (port) {
		port->retired = true;
		list_for_each_entry_safe(flow, next, &fe->flows, list) {
			if (flow->input != port && flow->output != port)
				continue;
			ret = rtl_fe_delete(fe, flow);
			if (ret)
				fe->error = ret;
		}
		rtl_fe_collect_ports(fe);
	}
	mutex_unlock(&fe->lock);
}

int rtl_fe_flush_port(struct rtl_fe *fe, struct net_device *netdev)
{
	int ret;

	if (!fe)
		return 0;

	mutex_lock(&fe->lock);
	ret = rtl_fe_flush_locked(fe, rtl_fe_port_find(fe, netdev));
	if (ret)
		fe->error = ret;
	mutex_unlock(&fe->lock);
	return ret;
}

int rtl_fe_set_itu_paths(struct rtl_fe *fe, struct net_device *netdev,
			 const struct rtl_itu_paths *paths)
{
	struct rtl_itu_paths *copy = NULL;
	int ret;

	if (!fe)
		return paths ? -EOPNOTSUPP : 0;

	if (paths) {
		copy = kvmemdup(paths, rtl_itu_paths_bytes(paths), GFP_KERNEL);
		if (!copy)
			return -ENOMEM;
	}

	mutex_lock(&fe->lock);
	ret = rtl_fe_flush_locked(fe, rtl_fe_port_find(fe, netdev));
	if (!ret) {
		kvfree(fe->itu_paths);
		fe->itu_paths = copy;
		fe->itu_netdev = paths ? netdev : NULL;
		copy = NULL;
	}
	mutex_unlock(&fe->lock);
	kvfree(copy);
	return ret;
}

static int rtl_fe_disable_locked(struct rtl_fe *fe)
{
	struct rtl_fe_flow *flow, *next;
	unsigned int i;
	int ret = 0;

	fe->enabled = false;
	if (fe->prepared) {
		for (i = 0; i < FE_LAN_PORTS; i++)
			rtl_fe_write(fe, RTL_NI_LAN_RX_CTRL(i), fe->lan_saved[i]);
		usleep_range(1000, 2000);
		list_for_each_entry_safe(flow, next, &fe->flows, list) {
			ret = rtl_fe_delete(fe, flow);
			if (ret)
				return ret;
		}
		ret = rtl_fe_restore(fe);
	}
	rtl_fe_collect_ports(fe);
	return ret;
}

static int rtl_fe_enable_locked(struct rtl_fe *fe)
{
	struct rtl_fe_port *port;
	unsigned int i;
	int ret;

	if (fe->prepared) {
		ret = rtl_fe_disable_locked(fe);
		if (ret)
			return ret;
	}
	ret = rtl_fe_prepare(fe);
	if (ret) {
		rtl_fe_restore(fe);
		return ret;
	}

	for (i = 0; i < FE_LAN_PORTS; i++)
		rtl_fe_rmw(fe, RTL_NI_LAN_RX_CTRL(i), GENMASK(21, 16), 25U << 16);
	list_for_each_entry(port, &fe->ports, list) {
		if (port->source != FE_SOURCE_P6)
			continue;
		rtl_fe_rmw(fe, RTL_NI_XGE_BYPASS_CFG, RTL_NI_XGE_BYPASS_FIELDS,
			   (fe->xge_saved & BIT(12)) | (25U << 4));
		break;
	}
	WRITE_ONCE(fe->enabled, true);
	return 0;
}

static int rtl_fe_flush_source_locked(struct rtl_fe *fe, unsigned int source)
{
	struct rtl_fe_port *port;
	int ret;

	list_for_each_entry(port, &fe->ports, list) {
		if (port->source != source)
			continue;
		ret = rtl_fe_flush_locked(fe, port);
		if (ret)
			return ret;
	}
	return 0;
}

int rtl_fe_pon_attach(struct rtl_fe *fe, bool attach)
{
	int ret = 0;

	if (!fe)
		return attach ? -EOPNOTSUPP : 0;

	mutex_lock(&fe->lock);
	fe->pon_attached = attach;
	if (!attach)
		ret = rtl_fe_flush_source_locked(fe, FE_SOURCE_PON);
	if (ret)
		fe->error = ret;
	mutex_unlock(&fe->lock);
	return ret;
}

void rtl_fe_start(struct rtl_fe *fe)
{
	int ret;

	if (!fe)
		return;

	mutex_lock(&fe->lock);
	ret = rtl_fe_enable_locked(fe);
	fe->error = ret;
	mutex_unlock(&fe->lock);
	if (ret)
		dev_err(fe->dev, "failed to start flow engine: %d\n", ret);
}

void rtl_fe_stop(struct rtl_fe *fe)
{
	int ret;

	if (!fe)
		return;

	mutex_lock(&fe->lock);
	ret = rtl_fe_disable_locked(fe);
	fe->error = ret;
	mutex_unlock(&fe->lock);
	if (ret)
		dev_err(fe->dev, "failed to stop flow engine: %d\n", ret);
}

static int rtl_fe_state_print(struct rtl_fe *fe, char *buffer, size_t size)
{
	unsigned int flows = 0, counted = 0, learned = 0;
	struct rtl_fe_flow *flow;
	int len;

	mutex_lock(&fe->lock);
	list_for_each_entry(flow, &fe->flows, list) {
		if (!flow->published)
			continue;
		flows++;
		counted += flow->counted;
		learned += flow->learned;
	}
	len = scnprintf(buffer, size,
			"available=1 enabled=%u prepared=%u pon_attached=%u bindings=%u error=%d flows=%u hash_entries=%u counter_slots=%u counted_flows=%u activity_flows=%u installs=%llu deletes=%llu rejected=%llu bridge_flows=%u\n",
			fe->enabled, fe->prepared, fe->pon_attached, fe->bindings,
			fe->error, flows, RTL_FE_HASH_ENTRIES, FE_COUNTERS,
			counted, flows - counted, fe->installs, fe->deletes,
			fe->misses, learned);
	mutex_unlock(&fe->lock);
	return len;
}

ssize_t rtl_fe_state(struct rtl_fe *fe, char *buffer)
{
	if (!fe)
		return sysfs_emit(buffer, "available=0\n");
	return rtl_fe_state_print(fe, buffer, PAGE_SIZE);
}

static int rtl_fe_state_show(struct seq_file *s, void *unused)
{
	char buffer[384];

	rtl_fe_state_print(s->private, buffer, sizeof(buffer));
	seq_puts(s, buffer);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(rtl_fe_state);

static int rtl_fe_flows_show(struct seq_file *s, void *unused)
{
	static const char * const kind[] = { "ipv4", "ipv6", "bridge" };
	struct rtl_fe *fe = s->private;
	struct rtl_fe_flow *flow;

	mutex_lock(&fe->lock);
	list_for_each_entry(flow, &fe->flows, list)
		seq_printf(s, "%s cookie=%lx in=%s out=%s hash=%u counter=%u packets=%u bytes=%llu learned=%u deleting=%u\n",
			   kind[flow->kind], flow->cookie,
			   flow->input->netdev->name, flow->output->netdev->name,
			   flow->hash_index, flow->counter, flow->packets,
			   flow->bytes, flow->learned, flow->deleting);
	mutex_unlock(&fe->lock);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(rtl_fe_flows);

static int rtl_fe_resources_show(struct seq_file *s, void *unused)
{
	unsigned int i, smac = 0, intf = 0, mtu = 0;
	struct rtl_fe *fe = s->private;

	mutex_lock(&fe->lock);
	for (i = 0; i < FE_SOURCE_MACS; i++)
		smac += !!fe->source_macs[i].users;
	for (i = 0; i < FE_INTERFACES; i++)
		intf += !!fe->interfaces[i].users;
	for (i = 0; i < FE_MTUS; i++)
		mtu += !!fe->mtus[i].users;
	seq_printf(s, "source_mac=%u/%u\n", smac, FE_SOURCE_MACS);
	seq_printf(s, "interface=%u/%u\n", intf, FE_INTERFACES);
	seq_printf(s, "mtu=%u/%u\n", mtu, FE_MTUS);
	seq_printf(s, "hash=%u/%u\n", bitmap_weight(fe->hashes, RTL_FE_HASH_ENTRIES),
		   RTL_FE_HASH_ENTRIES);
	seq_printf(s, "counted=%u/%u\n", bitmap_weight(fe->counters, FE_INTERFACES),
		   FE_COUNTERS);
	mutex_unlock(&fe->lock);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(rtl_fe_resources);

static void rtl_fe_debugfs_init(struct rtl_fe *fe)
{
	fe->debugfs = debugfs_create_dir(dev_name(fe->dev), NULL);
	debugfs_create_file("state", 0400, fe->debugfs, fe, &rtl_fe_state_fops);
	debugfs_create_file("flows", 0400, fe->debugfs, fe, &rtl_fe_flows_fops);
	debugfs_create_file("resources", 0400, fe->debugfs, fe,
			    &rtl_fe_resources_fops);
}

static int rtl_fe_netdev_event(struct notifier_block *nb, unsigned long event,
			       void *ptr)
{
	struct net_device *dev = netdev_notifier_info_to_dev(ptr);
	struct rtl_fe *fe = container_of(nb, struct rtl_fe, netdev_nb);
	struct rtl_fe_port *port;
	int ret;

	if (event != NETDEV_FEAT_CHANGE || tc_can_offload(dev))
		return NOTIFY_DONE;

	mutex_lock(&fe->lock);
	port = rtl_fe_port_find(fe, dev);
	if (port) {
		ret = rtl_fe_flush_locked(fe, port);
		if (ret)
			fe->error = ret;
	}
	mutex_unlock(&fe->lock);
	return NOTIFY_DONE;
}

static void rtl_fe_axi_reorder(struct rtl_fe *fe)
{
	writel(15, fe->axi + FE_REORDER_CTRL);
	writel(BIT(31) | 8, fe->axi + FE_REORDER_USER);
	writel(BIT(28), fe->axi + FE_REORDER_ATTR);
	writel(BIT(28), fe->axi + FE_REORDER_ATTR2);
	writel(BIT(31) | 9, fe->axi + FE_REORDER_ID);
	readl(fe->axi + FE_REORDER_ID);
}

struct rtl_fe *rtl_fe_create(struct device *dev, struct regmap *regs,
			     void __iomem *axi)
{
	struct rtl_fe *fe;
	u32 *defaults;
	unsigned int i;
	int ret;

	fe = kzalloc(sizeof(*fe), GFP_KERNEL);
	if (!fe)
		return ERR_PTR(-ENOMEM);
	fe->dev = dev;
	fe->regs = regs;
	fe->axi = axi;
	mutex_init(&fe->lock);
	INIT_DELAYED_WORK(&fe->cleanup_work, rtl_fe_cleanup_work);
	INIT_LIST_HEAD(&fe->ports);
	INIT_LIST_HEAD(&fe->flows);
	INIT_LIST_HEAD(&fe->blocks);
	INIT_LIST_HEAD(&fe->wifi_peers);

	fe->saved = kcalloc(ARRAY_SIZE(rtl_fe_saved_regs), sizeof(*fe->saved),
			    GFP_KERNEL);
	if (!fe->saved) {
		ret = -ENOMEM;
		goto free_fe;
	}

	ret = rhashtable_init(&fe->cookies, &rtl_fe_flow_params);
	if (ret)
		goto free_saved;

	fe->memory = dma_alloc_coherent(dev, RTL_FE_MEMORY_BYTES, &fe->dma,
					GFP_KERNEL);
	if (!fe->memory) {
		ret = -ENOMEM;
		goto destroy_hash;
	}
	defaults = fe->memory + RTL_FE_DEFAULT_OFFSET;
	for (i = 0; i < RTL_FE_DEFAULT_ENTRIES; i++)
		rtl_fe_cpu_miss(defaults + i * 4);
	dma_wmb();

	fe->bridge = rtl_fe_bridge_start(fe);
	if (IS_ERR(fe->bridge)) {
		ret = PTR_ERR(fe->bridge);
		goto free_memory;
	}

	fe->netdev_nb.notifier_call = rtl_fe_netdev_event;
	ret = register_netdevice_notifier(&fe->netdev_nb);
	if (ret)
		goto stop_bridge;

	rtl_fe_axi_reorder(fe);
	rtl_fe_debugfs_init(fe);
	return fe;

stop_bridge:
	rtl_fe_bridge_stop(fe->bridge);
free_memory:
	dma_free_coherent(dev, RTL_FE_MEMORY_BYTES, fe->memory, fe->dma);
destroy_hash:
	rhashtable_destroy(&fe->cookies);
free_saved:
	kfree(fe->saved);
free_fe:
	kfree(fe);
	return ERR_PTR(ret);
}

void rtl_fe_destroy(struct rtl_fe *fe)
{
	struct rtl_fe_flow *flow, *flow_next;
	struct rtl_fe_port *port, *next;

	if (!fe)
		return;

	debugfs_remove_recursive(fe->debugfs);
	unregister_netdevice_notifier(&fe->netdev_nb);
	rtl_fe_bridge_stop(fe->bridge);
	mutex_lock(&fe->lock);
	rtl_fe_disable_locked(fe);
	mutex_unlock(&fe->lock);
	cancel_delayed_work_sync(&fe->cleanup_work);
	list_for_each_entry_safe(flow, flow_next, &fe->flows, list) {
		list_del(&flow->list);
		kfree(flow);
	}
	rhashtable_destroy(&fe->cookies);
	list_for_each_entry_safe(port, next, &fe->ports, list) {
		list_del(&port->list);
		kfree(port);
	}
	{
		struct rtl_fe_wifi_peer *peer, *peer_next;
		list_for_each_entry_safe(peer, peer_next, &fe->wifi_peers, list) {
			list_del(&peer->list);
			kfree(peer);
		}
	}
	dma_free_coherent(fe->dev, RTL_FE_MEMORY_BYTES, fe->memory, fe->dma);
	kvfree(fe->itu_paths);
	kfree(fe->saved);
	kfree(fe);
}
