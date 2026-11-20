/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef RTL9617C_FE_H
#define RTL9617C_FE_H

#include <linux/device.h>
#include <linux/err.h>
#include <linux/netdevice.h>
#include <linux/regmap.h>

struct rtl_fe;
struct rtl_itu_paths;

#if IS_ENABLED(CONFIG_RTL9617C_FE)
struct rtl_fe *rtl_fe_create(struct device *dev, struct regmap *regs,
			     void __iomem *axi);
void rtl_fe_destroy(struct rtl_fe *fe);
int rtl_fe_add_port(struct rtl_fe *fe, struct net_device *netdev,
		    unsigned int source, unsigned int destination,
		    unsigned int llid);
/* CU WiFi-NE backport: NE Wi-Fi interface identity + peer routing. */
int rtl_fe_add_wifi_port(struct rtl_fe *fe, struct net_device *netdev,
			 unsigned int id);
int rtl_fe_wifi_peer_route(struct rtl_fe *fe, struct net_device *netdev,
			   const u8 *address, unsigned int destination);
bool rtl_fe_wifi_enabled(struct rtl_fe *fe);
void rtl_fe_remove_port(struct rtl_fe *fe, struct net_device *netdev);
int rtl_fe_flush_port(struct rtl_fe *fe, struct net_device *netdev);
int rtl_fe_setup_tc(struct rtl_fe *fe, struct net_device *netdev,
		    enum tc_setup_type type, void *data);
void rtl_fe_start(struct rtl_fe *fe);
void rtl_fe_stop(struct rtl_fe *fe);
int rtl_fe_pon_attach(struct rtl_fe *fe, bool attach);
ssize_t rtl_fe_state(struct rtl_fe *fe, char *buffer);
int rtl_fe_set_itu_paths(struct rtl_fe *fe, struct net_device *netdev,
			 const struct rtl_itu_paths *paths);
#else
static inline struct rtl_fe *rtl_fe_create(struct device *dev,
					   struct regmap *regs,
					   void __iomem *axi)
{
	return NULL;
}

static inline void rtl_fe_destroy(struct rtl_fe *fe)
{
}

static inline int rtl_fe_add_port(struct rtl_fe *fe, struct net_device *netdev,
				  unsigned int source, unsigned int destination,
				  unsigned int llid)
{
	return 0;
}

static inline int rtl_fe_add_wifi_port(struct rtl_fe *fe,
				       struct net_device *netdev,
				       unsigned int id)
{
	return -EOPNOTSUPP;
}

static inline int rtl_fe_wifi_peer_route(struct rtl_fe *fe,
					 struct net_device *netdev,
					 const u8 *address,
					 unsigned int destination)
{
	return -EOPNOTSUPP;
}

static inline bool rtl_fe_wifi_enabled(struct rtl_fe *fe)
{
	return false;
}

static inline void rtl_fe_remove_port(struct rtl_fe *fe,
				      struct net_device *netdev)
{
}

static inline int rtl_fe_flush_port(struct rtl_fe *fe, struct net_device *netdev)
{
	return 0;
}

static inline int rtl_fe_setup_tc(struct rtl_fe *fe, struct net_device *netdev,
				  enum tc_setup_type type, void *data)
{
	return -EOPNOTSUPP;
}

static inline void rtl_fe_start(struct rtl_fe *fe)
{
}

static inline void rtl_fe_stop(struct rtl_fe *fe)
{
}

static inline int rtl_fe_pon_attach(struct rtl_fe *fe, bool attach)
{
	return attach ? -EOPNOTSUPP : 0;
}

static inline ssize_t rtl_fe_state(struct rtl_fe *fe, char *buffer)
{
	return sysfs_emit(buffer, "available=0\n");
}

static inline int rtl_fe_set_itu_paths(struct rtl_fe *fe,
				       struct net_device *netdev,
				       const struct rtl_itu_paths *paths)
{
	return paths ? -EOPNOTSUPP : 0;
}
#endif

#endif
