// SPDX-License-Identifier: GPL-2.0-or-later
#include <linux/export.h>
#include <linux/netdevice.h>
#include <linux/rcupdate.h>

#include "ni.h"
#include "fe/fe.h"
#include "rtl9617c-wifi-format.h"

#define NI_REPORT_HIGH_SHIFT		14
#define NI_PUC_DEQUEUE_MASK		GENMASK(15, 0)
#define NI_OAM_PORT			12
#define NI_OAM_MAP_DEST			12

static struct rtl9617c_ni *rtl_ni_from_dev(struct device *dev)
{
	return dev_get_drvdata(dev);
}

int rtl9617c_ni_open(struct device *dev)
{
	return rtl_ni_engine_get(rtl_ni_from_dev(dev));
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_open);

void rtl9617c_ni_close(struct device *dev, struct net_device *owner)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);

	rtl_fe_flush_port(ni->fe, owner);
	rtl_ni_engine_put(ni);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_close);

netdev_tx_t rtl9617c_ni_transmit(struct device *dev, struct net_device *owner,
				 struct sk_buff *skb,
				 const struct rtl9617c_ni_frame *frame)
{
	return rtl_ni_xmit_frame(rtl_ni_from_dev(dev), owner, skb, frame);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_transmit);

int rtl9617c_ni_pon_attach(struct device *dev,
			   struct rtl9617c_ni_endpoint *endpoint)
{
	rcu_assign_pointer(rtl_ni_from_dev(dev)->pon, endpoint);
	return 0;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_pon_attach);

void rtl9617c_ni_pon_detach(struct device *dev)
{
	RCU_INIT_POINTER(rtl_ni_from_dev(dev)->pon, NULL);
	synchronize_net();
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_pon_detach);

u32 rtl9617c_ni_pon_gate(struct device *dev, u32 enabled)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);
	unsigned long flags;
	u32 saved;

	spin_lock_irqsave(&ni->tx_lock, flags);
	saved = rtl_ni_read(ni, RTL_NI_PUC_DEQUEUE);
	rtl_ni_write(ni, RTL_NI_PUC_DEQUEUE, (saved & ~NI_PUC_DEQUEUE_MASK) |
		     (enabled & NI_PUC_DEQUEUE_MASK));
	rtl_ni_read(ni, RTL_NI_PUC_DEQUEUE);
	spin_unlock_irqrestore(&ni->tx_lock, flags);
	return saved & NI_PUC_DEQUEUE_MASK;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_pon_gate);

int rtl9617c_ni_report_configure(struct device *dev, unsigned int low,
				 unsigned int high)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);

	if (!ni)
		return -EPROBE_DEFER;
	rtl_ni_write(ni, RTL_NI_REPORT, (high << NI_REPORT_HIGH_SHIFT) | low);
	return 0;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_report_configure);

u32 rtl9617c_ni_report_state(struct device *dev)
{
	return rtl_ni_read(rtl_ni_from_dev(dev), RTL_NI_REPORT);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_report_state);

int rtl9617c_ni_oam_configure(struct device *dev)
{
	static const unsigned int index[] = { 15, 0x8f, 0x4f, 0xcf };
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);
	unsigned int i;
	int ret;

	for (i = 0; i < ARRAY_SIZE(index); i++) {
		rtl_ni_write(ni, RTL_NI_QM_PORT_MAP_DATA, NI_OAM_MAP_DEST);
		ret = rtl_ne_table_write(ni->regs, RTL_NI_QM_PORT_MAP_CMD, index[i]);
		if (ret)
			return ret;
	}
	rtl_ni_write(ni, RTL_NI_PORT_TABLE_ENTRY(NI_OAM_PORT), 0xff | (6 << 16));
	rtl_ni_rmw(ni, RTL_NI_L2TM_ES_CTRL, BIT(NI_OAM_PORT), BIT(NI_OAM_PORT));
	return 0;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_oam_configure);

int rtl9617c_ni_mib_read(struct device *dev, unsigned int port,
			 u64 counters[RTL9617C_NI_MIB_COUNTERS])
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);
	int ret;

	if (port >= RTL_NI_GE_PORTS)
		return -EINVAL;

	mutex_lock(&ni->mib_lock);
	ret = rtl_ni_mib_update(ni, port);
	if (!ret)
		memcpy(counters, ni->mib[port], sizeof(ni->mib[port]));
	mutex_unlock(&ni->mib_lock);
	return ret;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_mib_read);

int rtl9617c_ni_fe_add_port(struct device *dev, struct net_device *netdev,
			    unsigned int llid)
{
	return rtl_fe_add_port(rtl_ni_from_dev(dev)->fe, netdev, RTL_NI_PORT_PON,
			       32 + llid, llid);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_fe_add_port);

void rtl9617c_ni_fe_remove_port(struct device *dev, struct net_device *netdev)
{
	rtl_fe_remove_port(rtl_ni_from_dev(dev)->fe, netdev);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_fe_remove_port);

int rtl9617c_ni_fe_setup_tc(struct device *dev, struct net_device *netdev,
			    enum tc_setup_type type, void *data)
{
	return rtl_fe_setup_tc(rtl_ni_from_dev(dev)->fe, netdev, type, data);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_fe_setup_tc);

int rtl9617c_ni_fe_attach(struct device *dev)
{
	return rtl_fe_pon_attach(rtl_ni_from_dev(dev)->fe, true);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_fe_attach);

int rtl9617c_ni_fe_detach(struct device *dev)
{
	return rtl_fe_pon_attach(rtl_ni_from_dev(dev)->fe, false);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_fe_detach);

ssize_t rtl9617c_ni_fe_state(struct device *dev, char *buffer)
{
	return rtl_fe_state(rtl_ni_from_dev(dev)->fe, buffer);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_fe_state);

int rtl9617c_ni_itu_paths(struct device *dev, struct net_device *netdev,
			  const struct rtl_itu_paths *paths)
{
	return rtl_fe_set_itu_paths(rtl_ni_from_dev(dev)->fe, netdev, paths);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_itu_paths);

/* ---- CU WiFi-NE backport: public Wi-Fi interface API ------------------ */
/* These bridge the backported rtl9617c-wifi.c glue to the refactor NI/FE/DMA
 * internals. Semantics mirror the base rtl9617c-xram.c implementations. */

int rtl9617c_ni_wifi_attach(struct device *dev,
			    struct rtl9617c_ni_wifi_endpoint *endpoint)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);
	unsigned int id;
	int ret;

	ASSERT_RTNL();
	if (!ni->fe || !ni->dma.desc) return -EOPNOTSUPP;
	for (id = 1; id <= RTL_WIFI_ID_MAX; id++)
		if (!rcu_access_pointer(ni->wifi[id])) break;
	if (id > RTL_WIFI_ID_MAX) return -ENOSPC;
	ret = rtl_ni_engine_get(ni);
	if (ret) return ret;
	ret = rtl_fe_add_wifi_port(ni->fe, endpoint->netdev, id);
	if (ret) { rtl_ni_engine_put(ni); return ret; }
	dev_hold(endpoint->netdev);
	rcu_assign_pointer(ni->wifi[id], endpoint);
	return id;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_wifi_attach);

int rtl9617c_ni_wifi_id(struct device *dev, struct net_device *netdev)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);
	unsigned int id;
	int ret = -ENODEV;

	rcu_read_lock();
	for (id = 1; id <= RTL_WIFI_ID_MAX; id++) {
		struct rtl9617c_ni_wifi_endpoint *endpoint =
			rcu_dereference(ni->wifi[id]);
		if (endpoint && endpoint->netdev == netdev) { ret = id; break; }
	}
	rcu_read_unlock();
	return ret;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_wifi_id);

int rtl9617c_ni_wifi_detach(struct device *dev, unsigned int id)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);
	struct rtl9617c_ni_wifi_endpoint *endpoint;
	unsigned long flags;
	int ret;

	ASSERT_RTNL();
	if (id < 1 || id > RTL_WIFI_ID_MAX) return -EINVAL;
	endpoint = rcu_access_pointer(ni->wifi[id]);
	if (!endpoint) return -ENODEV;
	/* Withdraw FE flows before releasing the identity. */
	ret = rtl_fe_flush_port(ni->fe, endpoint->netdev);
	if (ret && !ni->removing) return ret;
	/* Drain any in-flight shared-queue submissions for this NI. */
	spin_lock_irqsave(&ni->tx_lock, flags);
	rtl_ni_dma_reclaim(&ni->dma);
	spin_unlock_irqrestore(&ni->tx_lock, flags);
	usleep_range(1000, 2000);
	rcu_assign_pointer(ni->wifi[id], NULL);
	synchronize_net();
	dev_put(endpoint->netdev);
	rtl_ni_engine_put(ni);
	return 0;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_wifi_detach);

bool rtl9617c_ni_wifi_enabled(struct device *dev)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);

	return ni && rtl_fe_wifi_enabled(ni->fe);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_wifi_enabled);

int rtl9617c_ni_wifi_peer_route(struct device *dev, struct net_device *netdev,
				const u8 *address, unsigned int destination)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);

	return rtl_fe_wifi_peer_route(ni->fe, netdev, address, destination);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_wifi_peer_route);

int rtl9617c_ni_wifi_lookup(struct device *dev, struct sk_buff *skb,
			    unsigned int id)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);
	unsigned long flags;
	int ret;

	/* Base parity (rtl9617c-xram.c): this hook runs from NET_RX softirq while
	 * every other tx_lock user is irqsave. Plain spin_lock leaves hardirqs
	 * enabled and is a self-deadlock / lockup hazard on this SoC. */
	spin_lock_irqsave(&ni->tx_lock, flags);
	ret = rtl_ni_dma_xmit_wifi(&ni->dma, ni->napi_dev, skb, id);
	spin_unlock_irqrestore(&ni->tx_lock, flags);
	return ret;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_wifi_lookup);
