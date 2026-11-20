/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef RTL9617C_NI_PRIV_H
#define RTL9617C_NI_PRIV_H

#include <linux/atomic.h>
#include <linux/dma-mapping.h>
#include <linux/hrtimer.h>
#include <linux/if_vlan.h>
#include <linux/mutex.h>
#include <linux/netdevice.h>
#include <linux/phy.h>
#include <linux/phylink.h>
#include <linux/regmap.h>
#include <linux/spinlock.h>
#include <linux/workqueue.h>

#include "rtl9617c_ni.h"
#include "rtl9617c_regs.h"

#define RTL_NI_PORTS			7
#define RTL_NI_GE_PORTS			5
#define RTL_NI_PORT_P6			6
#define RTL_NI_PORT_PON			7
#define RTL_NI_CPU_PORT			0
#define RTL_NI_FRAME_MAX		(VLAN_ETH_FRAME_LEN + 4)
#define RTL_NI_TX_TIMER_NS		NSEC_PER_MSEC

#define RTL_NI_DMA_ORDER		6
#define RTL_NI_DMA_ENTRIES		BIT(RTL_NI_DMA_ORDER)
#define RTL_NI_DMA_BUF_SIZE		2048
#define RTL_NI_DMA_HDR_LEN		16
#define RTL_NI_DMA_VP			8
#define RTL_NI_DMA_GUARD		2

#define RTL_NI_QM_VOQS			8
#define RTL_NI_QM_RING_SIZE		1024
#define RTL_NI_QM_CMD_SIZE		8
#define RTL_NI_QM_EQ			4
#define RTL_NI_QM_EQS			2
#define RTL_NI_QM_EQ_BUFS		256
#define RTL_NI_QM_BUFS			(RTL_NI_QM_EQS * RTL_NI_QM_EQ_BUFS)
#define RTL_NI_QM_BUF_SIZE		2048
#define RTL_NI_QM_HEADROOM		64
#define RTL_NI_QM_TAILROOM		384
#define RTL_NI_QM_DATA_SIZE		(RTL_NI_QM_BUF_SIZE - RTL_NI_QM_HEADROOM - \
					 RTL_NI_QM_TAILROOM)
#define RTL_NI_QM_PE_EQ			6
#define RTL_NI_QM_PE_BUFS		2496
#define RTL_NI_DQ_BUFS			512
#define RTL_NI_DQ_BUF_SIZE		2048
#define RTL_NI_DQ_SIZE			(2 * RTL_NI_DQ_BUFS * RTL_NI_DQ_BUF_SIZE)

struct rtl9617c_ni;
struct rtl_fe;

struct rtl_ni_dma_desc {
	__le32 addr;
	__le32 ctrl;
};

struct rtl_ni_dma {
	void __iomem *base;
	struct rtl_ni_dma_desc *desc;
	void *mem;
	dma_addr_t mem_dma;
	unsigned int head;
	unsigned int tail;
};

struct rtl_ni_qm_refill {
	u32 addr[RTL_NI_QM_EQS][RTL_NI_QM_EQ_BUFS];
	unsigned int head[RTL_NI_QM_EQS];
	unsigned int count[RTL_NI_QM_EQS];
	unsigned int pending;
};

struct rtl_ni_qm {
	void __iomem *axi;
	void *buf;
	dma_addr_t buf_dma;
	void *ring;
	dma_addr_t ring_dma;
	void *dq;
	dma_addr_t dq_dma;
	unsigned int read[RTL_NI_QM_VOQS];
	struct rtl_ni_qm_refill refill;
	bool ready;
};

struct rtl9617c_ni_port {
	struct rtl9617c_ni *ni;
	struct net_device *dev;
	struct device_node *np;
	struct phylink *phylink;
	struct phylink_config phylink_config;
	struct phy *serdes;
	phy_interface_t interface;
	unsigned int id;
	bool registered;
};

struct rtl9617c_ni {
	struct device *dev;
	struct regmap *regs;
	void __iomem *reset;
	void __iomem *fe_axi;
	struct net_device *napi_dev;
	struct napi_struct napi;
	struct hrtimer timer;
	spinlock_t tx_lock;
	spinlock_t rx_lock;
	struct mutex lock;
	unsigned int users;
	bool rx_active;
	bool tx_stopped;
	int irq;
	struct rtl_ni_dma dma;
	struct rtl_ni_qm qm;
	struct rtl_fe *fe;
	struct rtl9617c_ni_port *ports[RTL_NI_PORTS];
	struct net_device __rcu *rx_dev[RTL_NI_PORTS];
	struct rtl9617c_ni_endpoint __rcu *pon;
	/* CU WiFi-NE backport: per-ID receive endpoints (0 unused, 1..60 APs). */
	struct rtl9617c_ni_wifi_endpoint __rcu *wifi[61];
	bool wifi_started;
	bool removing;
	u8 mac[ETH_ALEN];
	bool serdes_on;
	bool p6_ready;
	bool xge_bypass_saved;
	u32 xge_bypass;
	struct mutex mib_lock;
	struct delayed_work mib_work;
	u64 mib[RTL_NI_GE_PORTS][RTL9617C_NI_MIB_COUNTERS];
	atomic_long_t rx_errors;
	atomic_long_t rx_dropped;
};

static inline u32 rtl_ni_read(struct rtl9617c_ni *ni, unsigned int reg)
{
	return rtl_ne_read(ni->regs, reg);
}

static inline void rtl_ni_write(struct rtl9617c_ni *ni, unsigned int reg, u32 val)
{
	rtl_ne_write(ni->regs, reg, val);
}

static inline void rtl_ni_rmw(struct rtl9617c_ni *ni, unsigned int reg, u32 clear,
			      u32 set)
{
	rtl_ne_rmw(ni->regs, reg, clear, set);
}

static inline bool rtl_ni_is_ge(unsigned int id)
{
	return id < RTL_NI_GE_PORTS;
}

void rtl_ni_set_mac(struct rtl9617c_ni *ni);
int rtl_ni_engine_get(struct rtl9617c_ni *ni);
void rtl_ni_engine_put(struct rtl9617c_ni *ni);
netdev_tx_t rtl_ni_xmit_frame(struct rtl9617c_ni *ni, struct net_device *dev,
			      struct sk_buff *skb,
			      const struct rtl9617c_ni_frame *frame);
void rtl_ni_tx_restart(struct rtl9617c_ni *ni);

int rtl_ni_dma_alloc(struct rtl9617c_ni *ni);
int rtl_ni_dma_start(struct rtl_ni_dma *dma);
void rtl_ni_dma_stop(struct rtl_ni_dma *dma);
void rtl_ni_dma_reclaim(struct rtl_ni_dma *dma);
bool rtl_ni_dma_avail(struct rtl_ni_dma *dma);
int rtl_ni_dma_xmit(struct rtl_ni_dma *dma, struct sk_buff *skb,
		    const struct rtl9617c_ni_frame *frame);
/* CU WiFi-NE backport: downstream NE lookup injection (owns skb on success). */
int rtl_ni_dma_xmit_wifi(struct rtl_ni_dma *dma, struct net_device *dev,
			 struct sk_buff *skb, unsigned int id);

int rtl_ni_qm_alloc(struct rtl9617c_ni *ni);
void rtl_ni_qm_free(struct rtl9617c_ni *ni);
int rtl_ni_qm_start(struct rtl9617c_ni *ni);
void rtl_ni_qm_stop(struct rtl9617c_ni *ni);
int rtl_ni_qm_poll(struct rtl9617c_ni *ni, struct napi_struct *napi, int budget);

int rtl_ni_p6_bringup(struct rtl9617c_ni *ni);
int rtl_ni_p6_set_interface(struct rtl9617c_ni *ni, phy_interface_t interface);

int rtl_ni_ports_register(struct rtl9617c_ni *ni);
void rtl_ni_ports_unregister(struct rtl9617c_ni *ni);

void rtl_ni_mib_init(struct rtl9617c_ni *ni);
void rtl_ni_mib_exit(struct rtl9617c_ni *ni);
int rtl_ni_mib_update(struct rtl9617c_ni *ni, unsigned int port);
int rtl_ni_get_sset_count(struct net_device *dev, int sset);
void rtl_ni_get_strings(struct net_device *dev, u32 stringset, u8 *data);
void rtl_ni_get_ethtool_stats(struct net_device *dev,
			      struct ethtool_stats *stats, u64 *data);

#endif
