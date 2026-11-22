// SPDX-License-Identifier: GPL-2.0-or-later
#include <linux/export.h>
#include <linux/netdevice.h>
#include <linux/rcupdate.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/list.h>

#include "ni.h"
#include "fe/fe.h"

#define NI_OAM_PORT			12
#define NI_OAM_MAP_DEST			12
#define NI_OAM_ES_SPEED_10G		6

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
	saved = rtl_ni_read(ni, RTL_QM_ES_CTRL1);
	rtl_ni_write(ni, RTL_QM_ES_CTRL1,
		     (saved & ~RTL_QM_ES_CTRL1_PUC_EN) |
		     FIELD_PREP(RTL_QM_ES_CTRL1_PUC_EN, enabled));
	rtl_ni_read(ni, RTL_QM_ES_CTRL1);
	spin_unlock_irqrestore(&ni->tx_lock, flags);
	return FIELD_GET(RTL_QM_ES_CTRL1_PUC_EN, saved);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_pon_gate);

int rtl9617c_ni_report_configure(struct device *dev, unsigned int low,
				 unsigned int high)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);

	if (!ni)
		return -EPROBE_DEFER;
	rtl_ni_write(ni, RTL_TE_CB_VOQ_REPORT_THRSH,
		     FIELD_PREP(RTL_TE_CB_VOQ_REPORT_LV2, high) |
		     FIELD_PREP(RTL_TE_CB_VOQ_REPORT_LV1, low));
	return 0;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_report_configure);

u32 rtl9617c_ni_report_state(struct device *dev)
{
	return rtl_ni_read(rtl_ni_from_dev(dev), RTL_TE_CB_VOQ_REPORT_THRSH);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_report_state);

int rtl9617c_ni_oam_configure(struct device *dev)
{
	static const unsigned int index[] = {
		15,
		15 | RTL_L2FE_ARB_PDPID_MAP_MY_MAC,
		15 | RTL_L2FE_ARB_PDPID_MAP_POL,
		15 | RTL_L2FE_ARB_PDPID_MAP_POL | RTL_L2FE_ARB_PDPID_MAP_MY_MAC,
	};
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);
	unsigned int i;
	int ret;

	for (i = 0; i < ARRAY_SIZE(index); i++) {
		rtl_ni_write(ni, RTL_L2FE_ARB_PDPID_MAP_TBL_DATA,
			     FIELD_PREP(RTL_L2FE_ARB_PDPID_MAP_PDPID,
					NI_OAM_MAP_DEST));
		ret = rtl_ne_table_write(ni->regs,
					 RTL_L2FE_ARB_PDPID_MAP_TBL_ACCESS,
					 index[i]);
		if (ret)
			return ret;
	}
	rtl_ni_write(ni, RTL_L2TM_ES_SCH_CFG0(NI_OAM_PORT),
		     FIELD_PREP(RTL_L2TM_ES_SCH_VOQ_EN, 0xff) |
		     FIELD_PREP(RTL_L2TM_ES_SCH_SPEED, NI_OAM_ES_SPEED_10G));
	rtl_ni_rmw(ni, RTL_L2TM_ES_CTRL, BIT(NI_OAM_PORT), BIT(NI_OAM_PORT));
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


/* ===== CU WiFi-NE (Taurus) minimal identity glue =====
 * rtl_ax_ap runs its own PE1 packet engine (pe_probe) and needs only these
 * three NE identity symbols. No NETDEV ingress nf_hook is registered: the
 * dual-PE hardware path carries station traffic, so the legacy NE re-injection
 * hard-lock loop cannot occur. Additive to the native Taurus NI driver. */
#define TAURUS_WIFI_ID_MAX 60

static struct device *taurus_wifi_ni;

void taurus_wifi_publish(struct device *dev)
{
	taurus_wifi_ni = dev;
}
EXPORT_SYMBOL_GPL(taurus_wifi_publish);

void taurus_wifi_withdraw(struct device *dev)
{
	if (taurus_wifi_ni == dev)
		taurus_wifi_ni = NULL;
}
EXPORT_SYMBOL_GPL(taurus_wifi_withdraw);

struct taurus_wifi_id {
	struct list_head list;
	struct net_device *netdev;
	unsigned int id;
};
static LIST_HEAD(taurus_wifi_ids);
static spinlock_t taurus_wifi_ids_lock = __SPIN_LOCK_UNLOCKED(taurus_wifi_ids_lock);

int rtl9617c_wifi_id(struct net_device *netdev)
{
	struct taurus_wifi_id *e, *p;
	unsigned int id;
	unsigned long flags;

	spin_lock_irqsave(&taurus_wifi_ids_lock, flags);
	list_for_each_entry(e, &taurus_wifi_ids, list)
		if (e->netdev == netdev) {
			spin_unlock_irqrestore(&taurus_wifi_ids_lock, flags);
			return e->id;
		}
	for (id = 1; id <= TAURUS_WIFI_ID_MAX; id++) {
		bool used = false;
		list_for_each_entry(p, &taurus_wifi_ids, list)
			if (p->id == id) { used = true; break; }
		if (!used) break;
	}
	if (id > TAURUS_WIFI_ID_MAX) {
		spin_unlock_irqrestore(&taurus_wifi_ids_lock, flags);
		return -ENOSPC;
	}
	e = kzalloc(sizeof(*e), GFP_ATOMIC);
	if (!e) {
		spin_unlock_irqrestore(&taurus_wifi_ids_lock, flags);
		return -ENOMEM;
	}
	e->netdev = netdev;
	e->id = id;
	list_add_tail(&e->list, &taurus_wifi_ids);
	spin_unlock_irqrestore(&taurus_wifi_ids_lock, flags);
	return id;
}
EXPORT_SYMBOL_GPL(rtl9617c_wifi_id);

static struct rtl_fe *taurus_wifi_fe(void)
{
	struct rtl9617c_ni *ni;

	if (!taurus_wifi_ni)
		return NULL;
	ni = dev_get_drvdata(taurus_wifi_ni);
	return ni ? ni->fe : NULL;
}

int rtl9617c_wifi_peer_route(struct net_device *netdev, const u8 *address,
			     unsigned int destination)
{
	struct rtl_fe *fe = taurus_wifi_fe();

	if (!fe)
		return -ENODEV;
	return rtl_fe_wifi_peer_route(fe, netdev, address, destination);
}
EXPORT_SYMBOL_GPL(rtl9617c_wifi_peer_route);

int rtl9617c_wifi_setup_tc(struct net_device *netdev, enum tc_setup_type type,
			   void *data)
{
	struct rtl_fe *fe = taurus_wifi_fe();

	if (!fe)
		return -ENODEV;
	return rtl_fe_setup_tc(fe, netdev, type, data);
}
EXPORT_SYMBOL_GPL(rtl9617c_wifi_setup_tc);
