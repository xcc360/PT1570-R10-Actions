/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef RTL9617C_NI_H
#define RTL9617C_NI_H

#include <linux/device.h>
#include <linux/netdevice.h>

#define RTL9617C_NI_MIB_RX		26
#define RTL9617C_NI_MIB_TX		26
#define RTL9617C_NI_MIB_COUNTERS	(RTL9617C_NI_MIB_RX + RTL9617C_NI_MIB_TX)

struct rtl_itu_paths;

struct rtl9617c_ni_endpoint {
	struct net_device *netdev;
	void (*receive)(struct rtl9617c_ni_endpoint *endpoint,
			struct napi_struct *napi, struct sk_buff *skb,
			unsigned int source);
	void (*wake)(struct rtl9617c_ni_endpoint *endpoint);
};

struct rtl9617c_ni_frame {
	u32 header_high;
	u32 header_low;
	const u8 *prefix;
	unsigned int prefix_length;
	bool raw_payload;
	bool oam;
};

/* CU WiFi-NE backport: per-AP receive endpoint. The NE identifies the AP
 * by an interface ID carried in the EPP metadata; ingress frames are handed
 * back to the driver through ->receive(). */
struct rtl9617c_ni_wifi_endpoint {
	struct net_device *netdev;
	void (*receive)(struct rtl9617c_ni_wifi_endpoint *endpoint,
			struct sk_buff *skb, bool forwarded);
};

/* CU WiFi-NE backport: public glue for the backported rtl_ax_ap driver. */
int rtl9617c_ni_wifi_attach(struct device *dev,
			    struct rtl9617c_ni_wifi_endpoint *endpoint);
int rtl9617c_ni_wifi_detach(struct device *dev, unsigned int id);
int rtl9617c_ni_wifi_id(struct device *dev, struct net_device *netdev);
bool rtl9617c_ni_wifi_enabled(struct device *dev);
int rtl9617c_ni_wifi_peer_route(struct device *dev, struct net_device *netdev,
				const u8 *address, unsigned int destination);
/* Caller supplies an Ethernet skb and a registered NE Wi-Fi interface ID.
 * Zero consumes skb; negative errno leaves ownership with the caller. */
int rtl9617c_ni_wifi_lookup(struct device *dev, struct sk_buff *skb,
			    unsigned int id);

int rtl9617c_ni_open(struct device *dev);
void rtl9617c_ni_close(struct device *dev, struct net_device *owner);
netdev_tx_t rtl9617c_ni_transmit(struct device *dev, struct net_device *owner,
				 struct sk_buff *skb,
				 const struct rtl9617c_ni_frame *frame);
int rtl9617c_ni_pon_attach(struct device *dev,
			   struct rtl9617c_ni_endpoint *endpoint);
void rtl9617c_ni_pon_detach(struct device *dev);
u32 rtl9617c_ni_pon_gate(struct device *dev, u32 enabled);
int rtl9617c_ni_report_configure(struct device *dev, unsigned int low,
				 unsigned int high);
u32 rtl9617c_ni_report_state(struct device *dev);
int rtl9617c_ni_oam_configure(struct device *dev);
int rtl9617c_ni_mib_read(struct device *dev, unsigned int port,
			 u64 counters[RTL9617C_NI_MIB_COUNTERS]);

int rtl9617c_ni_fe_add_port(struct device *dev, struct net_device *netdev,
			    unsigned int llid);
void rtl9617c_ni_fe_remove_port(struct device *dev, struct net_device *netdev);
int rtl9617c_ni_fe_setup_tc(struct device *dev, struct net_device *netdev,
			    enum tc_setup_type type, void *data);
int rtl9617c_ni_fe_attach(struct device *dev);
int rtl9617c_ni_fe_detach(struct device *dev);
ssize_t rtl9617c_ni_fe_state(struct device *dev, char *buffer);
int rtl9617c_ni_itu_paths(struct device *dev, struct net_device *netdev,
			  const struct rtl_itu_paths *paths);

#endif
