/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef RTL9617C_FE_PRIV_H
#define RTL9617C_FE_PRIV_H

#include <linux/bitmap.h>
#include <linux/etherdevice.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/netdevice.h>
#include <linux/regmap.h>
#include <linux/rhashtable.h>
#include <linux/workqueue.h>
#include <net/flow_offload.h>

#include "rtl9617c_regs.h"
#include "fe.h"
#include "fe_hw.h"

/* Physical EIF rows: RTL9617C L3FE_GLB_EGRESS_L3_IF_TBL_ACCESS.addr[4:0].
 * ca-ne.ko fe_l3e_if_tbl_table @0x27cec0 declares 0x20 rows.
 * GPL rtk_8277c_asicDriver.c hashIntfIdx2HwIntfIdx_mapping maps hash
 * indices 32..63 to physical rows 16..31 with dual-header semantics;
 * they are not additional physical EIF rows. */
#define FE_INTERFACES			32
#define FE_COUNTERS			32
#define FE_SOURCE_MACS			15
#define FE_LAN_PORTS			5
#define FE_MTUS				16
#define FE_CAM_PROTOCOLS		3
#define FE_LPB_ENTRIES			2
#define FE_DEEPQ_DEST			32
#define FE_SOURCE_P6			6
#define FE_SOURCE_PON			7

struct rtl_fe_bridge;
struct rtl_itu_paths;

struct rtl_fe_cam_protocol {
	u32 saved[RTL_FE_CAM_WORDS];
	u8 bank;
	u8 index;
	bool created;
};

struct rtl_fe_port {
	struct list_head list;
	struct rtl_fe *fe;
	struct net_device *netdev;
	unsigned int source;
	unsigned int destination;
	unsigned int llid;
	/* CU WiFi-NE backport: nonzero NE interface ID for an AP netdev. */
	unsigned int wifi_id;
	unsigned int bindings;
	bool retired;
};

/* CU WiFi-NE backport: learned Wi-Fi station route (STA MAC -> output). */
struct rtl_fe_wifi_peer {
	struct list_head list;
	struct rtl_fe_port *port;
	u8 address[ETH_ALEN];
	unsigned int destination;
};

struct rtl_fe_mac {
	unsigned int users;
	u32 saved[RTL_FE_SMAC_WORDS];
	u8 address[ETH_ALEN];
};

struct rtl_fe_interface {
	unsigned int users;
	u32 saved;
	unsigned int source_mac;
	unsigned int pppoe;
	bool counted;
};

struct rtl_fe_mtu {
	unsigned int users;
	unsigned int size;
	unsigned int saved;
};

struct rtl_fe_bridge_tag {
	u16 tci;
	u16 protocol;
};

struct rtl_fe_flow {
	struct rhash_head node;
	struct list_head list;
	unsigned long cookie;
	unsigned long lastused;
	struct rtl_fe_port *input;
	struct rtl_fe_port *output;
	enum rtl_fe_rule_kind kind;
	unsigned int hash_index;
	unsigned int counter;
	unsigned int source_mac;
	unsigned int destination_index;
	u32 destination_saved[RTL_FE_FDB_WORDS];
	unsigned int pppoe;
	unsigned int mtu_index;
	unsigned int ingress_session;
	u16 crc16;
	u16 ethernet_protocol;
	u8 ethernet_bytes;
	u8 ethernet_source[ETH_ALEN];
	u8 destination[ETH_ALEN];
	u64 bytes;
	u32 packets;
	bool learned;
	unsigned int bridge_index;
	unsigned int bridge_ingress;
	unsigned int bridge_egress;
	u16 bridge_vid;
	u16 bridge_ppp_protocol;
	u8 bridge_tags;
	struct rtl_fe_bridge_tag bridge_tag[2];
	bool destination_created;
	bool destination_owned;
	bool source_owned;
	bool interface_owned;
	bool mtu_owned;
	bool counted;
	bool hashed;
	bool published;
	bool installed;
	bool deleting;
};

struct rtl_fe_rule {
	enum rtl_fe_rule_kind kind;
	struct rtl_fe_key key;
	struct rtl_fe_action action;
	struct rtl_fe_port *input;
	struct rtl_fe_port *output;
	struct rtl_fe_vlan vlan[2];
	u8 vlan_count;
	bool vlan_exact;
	u16 ingress_tci[2];
	u8 ppp_protocol_slot;
	u16 ethernet_protocol;
	bool pppoe_input;
	unsigned int pppoe_session;
	unsigned int egress_pppoe;
	unsigned int mtu;
	u8 ethernet_bytes;
	u8 source[ETH_ALEN];
	u8 destination[ETH_ALEN];
};

struct rtl_fe {
	struct device *dev;
	struct regmap *regs;
	void __iomem *axi;
	struct mutex lock;
	struct delayed_work cleanup_work;
	struct list_head ports;
	struct list_head flows;
	struct list_head blocks;
	/* CU WiFi-NE backport: learned Wi-Fi peer routes. */
	struct list_head wifi_peers;
	struct rhashtable cookies;
	void *memory;
	dma_addr_t dma;
	struct notifier_block netdev_nb;
	unsigned int bindings;
	bool pon_attached;
	bool enabled;
	bool prepared;
	int error;
	u64 installs;
	u64 deletes;
	u64 misses;
	u32 *saved;
	u32 mask_saved[RTL_FE_MASK_WORDS];
	u32 bridge_mask_saved[3][RTL_FE_MASK_WORDS];
	struct rtl_fe_cam_protocol protocol_cam[FE_CAM_PROTOCOLS];
	u8 ppp_protocol_ids[2];
	u32 lan_saved[FE_LAN_PORTS];
	/* CU WiFi-NE backport: saved IPPB source override for Wi-Fi descriptor. */
	u32 wifi_ippb_saved;
	u32 xge_saved;
	u32 classifier_saved[FE_LPB_ENTRIES][RTL_FE_CLASSIFIER_WORDS];
	u32 map_saved[FE_LPB_ENTRIES][4];
	struct rtl_fe_mac source_macs[FE_SOURCE_MACS];
	struct rtl_fe_interface interfaces[FE_INTERFACES];
	struct rtl_fe_mtu mtus[FE_MTUS];
	struct rtl_itu_paths *itu_paths;
	struct net_device *itu_netdev;
	struct rtl_fe_bridge *bridge;
	struct dentry *debugfs;
	DECLARE_BITMAP(hashes, RTL_FE_HASH_ENTRIES);
	DECLARE_BITMAP(counters, FE_INTERFACES);
};

static inline u32 rtl_fe_read(struct rtl_fe *fe, unsigned int reg)
{
	return rtl_ne_read(fe->regs, reg);
}

static inline void rtl_fe_write(struct rtl_fe *fe, unsigned int reg, u32 val)
{
	rtl_ne_write(fe->regs, reg, val);
}

static inline void rtl_fe_rmw(struct rtl_fe *fe, unsigned int reg, u32 clear,
			      u32 set)
{
	rtl_ne_rmw(fe->regs, reg, clear, set);
}

static inline bool rtl_fe_is_enabled(struct rtl_fe *fe)
{
	return READ_ONCE(fe->enabled);
}

static inline bool rtl_fe_has_bindings(struct rtl_fe *fe)
{
	return READ_ONCE(fe->bindings);
}

struct rtl_fe_port *rtl_fe_port_find(struct rtl_fe *fe, struct net_device *netdev);
int rtl_fe_vlan_tpid(__be16 protocol);
int rtl_fe_install(struct rtl_fe_port *port, struct rtl_fe_rule *rule,
		   unsigned long cookie, struct rtl_fe_flow **out);
int rtl_fe_delete(struct rtl_fe *fe, struct rtl_fe_flow *flow);

int rtl_fe_itu_rule(struct rtl_fe_rule *rule);
int rtl_fe_itu_learn(struct rtl_fe_rule *rule, unsigned int gem, u64 generation);

struct rtl_fe_bridge *rtl_fe_bridge_start(struct rtl_fe *fe);
void rtl_fe_bridge_stop(struct rtl_fe_bridge *bridge);
void rtl_fe_bridge_flow_removed(struct rtl_fe *fe);

#endif
