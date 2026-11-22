// SPDX-License-Identifier: GPL-2.0-or-later
#include <linux/bitfield.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_net.h>
#include <linux/platform_device.h>
#include <linux/unaligned.h>

#include "ni.h"

/* CU WiFi-NE (Taurus) identity glue hooks. */
void taurus_wifi_publish(struct device *dev);
void taurus_wifi_withdraw(struct device *dev);
#include "fe/fe.h"

#define L2TM_QM_EQ_INIT			(RTL_L2TM_QM_EQ1_EN | \
					 FIELD_PREP(RTL_L2TM_QM_EQ1_PRVT, 29) | \
					 FIELD_PREP(RTL_L2TM_QM_EQ1_BUFNUM, 4))
#define L2TM_QM_PRVT_DEFAULT		29
#define L2TM_QM_GLOB_BUF_INIT		(FIELD_PREP(RTL_L2TM_QM_GLOB_NONCONG, 2048) | \
					 RTL_L2TM_QM_GLOB_DROP_EN | \
					 FIELD_PREP(RTL_L2TM_QM_GLOB_NODROP, 33))
#define L2TM_ES_CPU_PORT		14
#define PORT_RX_CTRL_MASK		(RTL_NI_PORT_RX_CTRL_BYP_NDRP | \
					 RTL_NI_PORT_RX_CTRL_BYP_EN | \
					 RTL_NI_PORT_RX_CTRL_BYP_DPID)
#define PORT_RX_CTRL_CPU		(RTL_NI_PORT_RX_CTRL_BYP_EN | \
					 FIELD_PREP(RTL_NI_PORT_RX_CTRL_BYP_DPID, 16))
#define GLB_PORT_TO_CPU_DMA		0xf
#define QM_EPP64_IRQ_MASK		RTL_QM_EPP64_P0_INT_EN
/*
 * Assert global L2TE XOFF well above L2TM_QM_GLOB_BUF_INIT's 33-buffer
 * no-drop floor (0x21) so ingress PAUSE throttles bursts before L2TM drops
 * frames.
 */
#define L2TE_CB_GLB_LTH_BUFS		1024
#define L2TE_CB_GLB_HTH_BUFS		2048

static const struct regmap_config rtl_ni_regmap_config = {
	.reg_bits = 32,
	.val_bits = 32,
	.reg_stride = 4,
	.max_register = RTL_NI_MAX_REGISTER,
	.fast_io = true,
};

static void rtl_ni_irq_enable(struct rtl9617c_ni *ni, bool enable)
{
	rtl_ni_rmw(ni, RTL_QM_EPP64_P3_0_INT_EN, QM_EPP64_IRQ_MASK,
		   enable ? QM_EPP64_IRQ_MASK : 0);
}

static void rtl_ni_wake_queues(struct rtl9617c_ni *ni)
{
	struct rtl9617c_ni_endpoint *endpoint;
	unsigned int id;

	for (id = 0; id < RTL_NI_PORTS; id++) {
		struct rtl9617c_ni_port *port = ni->ports[id];

		if (port && netif_running(port->dev))
			netif_wake_queue(port->dev);
	}

	rcu_read_lock();
	endpoint = rcu_dereference(ni->pon);
	if (endpoint)
		endpoint->wake(endpoint);
	rcu_read_unlock();
}

static void rtl_ni_stop_queues(struct rtl9617c_ni *ni)
{
	unsigned int id;

	ni->tx_stopped = true;
	for (id = 0; id < RTL_NI_PORTS; id++)
		if (ni->ports[id])
			netif_stop_queue(ni->ports[id]->dev);
	hrtimer_start(&ni->timer, ns_to_ktime(RTL_NI_TX_TIMER_NS),
		      HRTIMER_MODE_REL_SOFT);
}

static enum hrtimer_restart rtl_ni_timer(struct hrtimer *timer)
{
	struct rtl9617c_ni *ni = container_of(timer, struct rtl9617c_ni, timer);
	enum hrtimer_restart restart = HRTIMER_NORESTART;
	unsigned long flags;

	if (READ_ONCE(ni->qm.refill.pending))
		napi_schedule(&ni->napi);

	spin_lock_irqsave(&ni->tx_lock, flags);
	if (ni->tx_stopped) {
		rtl_ni_dma_reclaim(&ni->dma);
		if (rtl_ni_dma_avail(&ni->dma)) {
			ni->tx_stopped = false;
			rtl_ni_wake_queues(ni);
		} else {
			hrtimer_forward_now(timer, ns_to_ktime(RTL_NI_TX_TIMER_NS));
			restart = HRTIMER_RESTART;
		}
	}
	spin_unlock_irqrestore(&ni->tx_lock, flags);
	return restart;
}

netdev_tx_t rtl_ni_xmit_frame(struct rtl9617c_ni *ni, struct net_device *dev,
			      struct sk_buff *skb,
			      const struct rtl9617c_ni_frame *frame)
{
	unsigned int len = skb->len;
	unsigned long flags;
	int ret;

	spin_lock_irqsave(&ni->tx_lock, flags);
	ret = rtl_ni_dma_xmit(&ni->dma, skb, frame);
	if (ret == -ENOSPC) {
		netif_stop_queue(dev);
		rtl_ni_stop_queues(ni);
		spin_unlock_irqrestore(&ni->tx_lock, flags);
		return NETDEV_TX_BUSY;
	}
	if (!ret && !rtl_ni_dma_avail(&ni->dma))
		rtl_ni_stop_queues(ni);
	spin_unlock_irqrestore(&ni->tx_lock, flags);

	if (ret) {
		DEV_STATS_INC(dev, tx_dropped);
		dev_kfree_skb_any(skb);
	} else {
		DEV_STATS_INC(dev, tx_packets);
		DEV_STATS_ADD(dev, tx_bytes, len);
		dev_consume_skb_any(skb);
	}
	return NETDEV_TX_OK;
}

void rtl_ni_tx_restart(struct rtl9617c_ni *ni)
{
	unsigned long flags;
	int ret;

	spin_lock_irqsave(&ni->tx_lock, flags);
	rtl_ni_dma_stop(&ni->dma);
	ret = rtl_ni_dma_start(&ni->dma);
	if (!ret) {
		ni->tx_stopped = false;
		rtl_ni_wake_queues(ni);
	}
	spin_unlock_irqrestore(&ni->tx_lock, flags);
	if (ret)
		dev_err(ni->dev, "TX DMA restart failed: %d\n", ret);
}

static int rtl_ni_poll(struct napi_struct *napi, int budget)
{
	struct rtl9617c_ni *ni = container_of(napi, struct rtl9617c_ni, napi);
	unsigned long flags;
	int done;

	done = rtl_ni_qm_poll(ni, napi, budget);
	if (done < budget && napi_complete_done(napi, done)) {
		spin_lock_irqsave(&ni->rx_lock, flags);
		if (ni->rx_active)
			rtl_ni_irq_enable(ni, true);
		spin_unlock_irqrestore(&ni->rx_lock, flags);
	}
	if (READ_ONCE(ni->qm.refill.pending))
		hrtimer_start(&ni->timer, ns_to_ktime(RTL_NI_TX_TIMER_NS),
			      HRTIMER_MODE_REL_SOFT);
	return done;
}

static irqreturn_t rtl_ni_irq(int irq, void *data)
{
	struct rtl9617c_ni *ni = data;

	spin_lock(&ni->rx_lock);
	rtl_ni_irq_enable(ni, false);
	spin_unlock(&ni->rx_lock);
	napi_schedule_irqoff(&ni->napi);
	return IRQ_HANDLED;
}

void rtl_ni_set_mac(struct rtl9617c_ni *ni)
{
	rtl_ni_write(ni, RTL_NI_GLB_MAC_ADDR_CFG0, get_unaligned_be32(ni->mac));
	rtl_ni_rmw(ni, RTL_NI_GLB_MAC_ADDR_CFG1, RTL_NI_GLB_MAC_ADDR1_MASK,
		   ni->mac[4]);
}

static void rtl_ni_l2te_fc_enable(struct rtl9617c_ni *ni, bool enable)
{
	if (enable) {
		rtl_ni_write(ni, RTL_L2TE_CB_GLB_THRSH,
			     FIELD_PREP(RTL_L2TE_CB_GLB_THRSH_HTH,
					L2TE_CB_GLB_HTH_BUFS) |
			     FIELD_PREP(RTL_L2TE_CB_GLB_THRSH_LTH,
					L2TE_CB_GLB_LTH_BUFS));
		rtl_ni_rmw(ni, RTL_L2TE_FC_GLB_TIMER, 0,
			   RTL_L2TE_FC_GLB_TIMER_EN);
		return;
	}

	rtl_ni_rmw(ni, RTL_L2TE_FC_GLB_TIMER, RTL_L2TE_FC_GLB_TIMER_EN, 0);
}

static int rtl_ni_engine_start(struct rtl9617c_ni *ni)
{
	unsigned long flags;
	unsigned int id;
	u32 cfg;
	int ret;

	rtl_ni_p6_bringup(ni);

	rtl_ni_write(ni, RTL_L2TM_QM_EQ_CFG, L2TM_QM_EQ_INIT);
	rtl_ni_rmw(ni, RTL_L2TM_QM_PORT_PRVT_PROFILE(0),
		   RTL_L2TM_QM_PRVT_CNT_EVEN,
		   FIELD_PREP(RTL_L2TM_QM_PRVT_CNT_EVEN, L2TM_QM_PRVT_DEFAULT));
	rtl_ni_write(ni, RTL_L2TM_QM_GLOB_BUF_CFG, L2TM_QM_GLOB_BUF_INIT);
	rtl_ni_rmw(ni, RTL_L2TM_ES_SCH_CFG0(L2TM_ES_CPU_PORT),
		   RTL_L2TM_ES_SCH_VOQ_EN, RTL_L2TM_ES_SCH_VOQ_EN);
	rtl_ni_rmw(ni, RTL_L2TM_ES_CTRL,
		   RTL_L2TM_ES_CTRL_TX_EN | RTL_L2TM_ES_CTRL_CPU,
		   RTL_L2TM_ES_CTRL_TX_EN | RTL_L2TM_ES_CTRL_CPU);
	for (id = 0; id < RTL_NI_PORTS; id++) {
		if (!ni->ports[id])
			continue;
		if (rtl_ni_is_ge(id))
			rtl_ni_rmw(ni, RTL_L2TM_ES_CTRL,
				   RTL_L2TM_ES_CTRL_TX_EN | BIT(id),
				   RTL_L2TM_ES_CTRL_TX_EN | BIT(id));
		rtl_ni_rmw(ni, RTL_L2TM_ES_SCH_CFG0(id),
			   RTL_L2TM_ES_SCH_VOQ_EN, RTL_L2TM_ES_SCH_VOQ_EN);
	}

	ret = rtl_ni_dma_start(&ni->dma);
	if (ret)
		return ret;
	ret = rtl_ni_qm_start(ni);
	if (ret) {
		rtl_ni_dma_stop(&ni->dma);
		return ret;
	}

	for (id = 0; id < RTL_NI_GE_PORTS; id++)
		if (ni->ports[id])
			rtl_ni_rmw(ni, RTL_NI_PORT_RX_CTRL(id),
				   PORT_RX_CTRL_MASK, PORT_RX_CTRL_CPU);
	if (ni->ports[RTL_NI_PORT_P6]) {
		ni->xge_bypass = rtl_ni_read(ni, RTL_NI_XGE_BYPASS_CFG);
		ni->xge_bypass_saved = true;
		rtl_ni_rmw(ni, RTL_NI_XGE_BYPASS_CFG, RTL_NI_XGE_BYPASS_FIELDS,
			   RTL_NI_XGE_BYPASS_CPU0);
	}

	rtl_ni_rmw(ni, RTL_NI_GLB_STATIC, RTL_NI_GLB_PORT_TO_CPU, GLB_PORT_TO_CPU_DMA);
	rtl_ni_rmw(ni, RTL_L2TM_ES_CTRL,
		   RTL_L2TM_ES_CTRL_PORTS | RTL_L2TM_ES_CTRL_TX_EN,
		   RTL_L2TM_ES_CTRL_PORTS | RTL_L2TM_ES_CTRL_TX_EN);
	rtl_ni_l2te_fc_enable(ni, true);

	rtl_ni_set_mac(ni);
	rtl_ni_write(ni, RTL_NI_RX_ADDR, (RTL_NI_XRAM_RX_END - 1) << 16);
	rtl_ni_write(ni, RTL_NI_TX_ADDR, (RTL_NI_XRAM_TX_END - 1) << 16 |
		     RTL_NI_XRAM_TX_START);
	cfg = rtl_ni_read(ni, RTL_NI_XRAM_CFG) & ~RTL_NI_XRAM_RX_PROMISC;
	rtl_ni_write(ni, RTL_NI_XRAM_CFG, cfg | RTL_NI_XRAM_CPU_DISABLE);
	usleep_range(100, 200);
	rtl_ni_write(ni, RTL_NI_XRAM_CFG, cfg | RTL_NI_XRAM_CPU_DISABLE);

	ni->tx_stopped = false;
	napi_enable(&ni->napi);
	spin_lock_irqsave(&ni->rx_lock, flags);
	ni->rx_active = true;
	rtl_ni_irq_enable(ni, true);
	spin_unlock_irqrestore(&ni->rx_lock, flags);
	rtl_fe_start(ni->fe);
	return 0;
}

static void rtl_ni_engine_stop(struct rtl9617c_ni *ni)
{
	unsigned long flags;

	rtl_fe_stop(ni->fe);
	rtl_ni_l2te_fc_enable(ni, false);
	hrtimer_cancel(&ni->timer);
	if (ni->xge_bypass_saved) {
		rtl_ni_rmw(ni, RTL_NI_XGE_BYPASS_CFG, RTL_NI_XGE_BYPASS_FIELDS,
			   ni->xge_bypass & RTL_NI_XGE_BYPASS_FIELDS);
		ni->xge_bypass_saved = false;
	}

	spin_lock_irqsave(&ni->rx_lock, flags);
	ni->rx_active = false;
	rtl_ni_irq_enable(ni, false);
	spin_unlock_irqrestore(&ni->rx_lock, flags);
	synchronize_irq(ni->irq);
	napi_disable(&ni->napi);
	hrtimer_cancel(&ni->timer);

	spin_lock_irqsave(&ni->rx_lock, flags);
	rtl_ni_qm_stop(ni);
	spin_unlock_irqrestore(&ni->rx_lock, flags);

	spin_lock_irqsave(&ni->tx_lock, flags);
	rtl_ni_dma_stop(&ni->dma);
	spin_unlock_irqrestore(&ni->tx_lock, flags);
	rtl_ni_rmw(ni, RTL_NI_XRAM_CFG, RTL_NI_XRAM_CPU_DISABLE,
		   RTL_NI_XRAM_CPU_DISABLE);
}

int rtl_ni_engine_get(struct rtl9617c_ni *ni)
{
	int ret = 0;

	mutex_lock(&ni->lock);
	if (!ni->users)
		ret = rtl_ni_engine_start(ni);
	if (!ret)
		ni->users++;
	mutex_unlock(&ni->lock);
	return ret;
}

void rtl_ni_engine_put(struct rtl9617c_ni *ni)
{
	mutex_lock(&ni->lock);
	if (!WARN_ON_ONCE(!ni->users) && !--ni->users)
		rtl_ni_engine_stop(ni);
	mutex_unlock(&ni->lock);
}

static int rtl_ni_base_mac(struct rtl9617c_ni *ni)
{
	int ret;

	ret = of_get_mac_address(ni->dev->of_node, ni->mac);
	if (ret == -EPROBE_DEFER)
		return ret;
	if (ret || !is_valid_ether_addr(ni->mac))
		eth_random_addr(ni->mac);
	return 0;
}

static void rtl_ni_napi_del(void *data)
{
	struct rtl9617c_ni *ni = data;

	netif_napi_del(&ni->napi);
	free_netdev(ni->napi_dev);
}

static void rtl_ni_qm_release(void *data)
{
	rtl_ni_qm_free(data);
}

static int rtl_ni_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct rtl9617c_ni *ni;
	void __iomem *base;
	int ret;

	dev_info(dev, "enter rtl_ni_probe\n");

	ni = devm_kzalloc(dev, sizeof(*ni), GFP_KERNEL);
	if (!ni) {
		dev_err(dev, "devm_kzalloc failed\n");
		return -ENOMEM;
	}
	ni->dev = dev;
	spin_lock_init(&ni->tx_lock);
	spin_lock_init(&ni->rx_lock);
	ret = devm_mutex_init(dev, &ni->lock);
	if (ret) {
		dev_err(dev, "devm_mutex_init(lock) failed: %d\n", ret);
		return ret;
	}
	ret = devm_mutex_init(dev, &ni->mib_lock);
	if (ret) {
		dev_err(dev, "devm_mutex_init(mib_lock) failed: %d\n", ret);
		return ret;
	}
	atomic_long_set(&ni->rx_errors, 0);
	atomic_long_set(&ni->rx_dropped, 0);

	base = devm_platform_ioremap_resource_byname(pdev, "ni");
	if (IS_ERR(base)) {
		dev_err(dev, "ioremap ni failed: %ld\n", PTR_ERR(base));
		return PTR_ERR(base);
	}
	ni->regs = devm_regmap_init_mmio(dev, base, &rtl_ni_regmap_config);
	if (IS_ERR(ni->regs)) {
		dev_err(dev, "regmap_init_mmio failed: %ld\n",
			PTR_ERR(ni->regs));
		return PTR_ERR(ni->regs);
	}
	ni->dma.base = devm_platform_ioremap_resource_byname(pdev, "dma");
	if (IS_ERR(ni->dma.base)) {
		dev_err(dev, "ioremap dma failed: %ld\n",
			PTR_ERR(ni->dma.base));
		return PTR_ERR(ni->dma.base);
	}
	ni->qm.axi = devm_platform_ioremap_resource_byname(pdev, "qm-axi");
	if (IS_ERR(ni->qm.axi)) {
		dev_err(dev, "ioremap qm-axi failed: %ld\n",
			PTR_ERR(ni->qm.axi));
		return PTR_ERR(ni->qm.axi);
	}
	ni->reset = devm_platform_ioremap_resource_byname(pdev, "reset");
	if (IS_ERR(ni->reset)) {
		dev_err(dev, "ioremap reset failed: %ld\n",
			PTR_ERR(ni->reset));
		return PTR_ERR(ni->reset);
	}
	if (IS_ENABLED(CONFIG_RTL9617C_FE)) {
		ni->fe_axi = devm_platform_ioremap_resource_byname(pdev, "fe-axi");
		if (IS_ERR(ni->fe_axi)) {
			dev_err(dev, "ioremap fe-axi failed: %ld\n",
				PTR_ERR(ni->fe_axi));
			return PTR_ERR(ni->fe_axi);
		}
	}

	ni->irq = platform_get_irq(pdev, 0);
	if (ni->irq < 0) {
		dev_err(dev, "platform_get_irq failed: %d\n", ni->irq);
		return ni->irq;
	}

	ret = rtl_ni_base_mac(ni);
	if (ret) {
		dev_err(dev, "rtl_ni_base_mac failed: %d\n", ret);
		return ret;
	}

	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (ret) {
		dev_err(dev, "dma_set_mask_and_coherent failed: %d\n", ret);
		return ret;
	}
	ret = rtl_ni_dma_alloc(ni);
	if (ret) {
		dev_err(dev, "rtl_ni_dma_alloc failed: %d\n", ret);
		return ret;
	}
	ret = rtl_ni_qm_alloc(ni);
	if (ret) {
		dev_err(dev, "rtl_ni_qm_alloc failed: %d\n", ret);
		return ret;
	}
	ret = devm_add_action_or_reset(dev, rtl_ni_qm_release, ni);
	if (ret) {
		dev_err(dev, "devm_add_action(qm_release) failed: %d\n", ret);
		return ret;
	}

	ni->napi_dev = alloc_netdev_dummy(0);
	if (!ni->napi_dev) {
		dev_err(dev, "alloc_netdev_dummy failed\n");
		return -ENOMEM;
	}
	netif_napi_add(ni->napi_dev, &ni->napi, rtl_ni_poll);
	ret = devm_add_action_or_reset(dev, rtl_ni_napi_del, ni);
	if (ret) {
		dev_err(dev, "devm_add_action(napi_del) failed: %d\n", ret);
		return ret;
	}
	hrtimer_setup(&ni->timer, rtl_ni_timer, CLOCK_MONOTONIC,
		      HRTIMER_MODE_REL_SOFT);

	rtl_ni_irq_enable(ni, false);
	ret = devm_request_irq(dev, ni->irq, rtl_ni_irq, 0, KBUILD_MODNAME, ni);
	if (ret) {
		dev_err(dev, "devm_request_irq(%d) failed: %d\n",
			ni->irq, ret);
		return ret;
	}

	ni->fe = rtl_fe_create(dev, ni->regs, ni->fe_axi,
			       ni->qm.lan_dq_bufs > 0);
	if (IS_ERR(ni->fe)) {
		dev_err(dev, "rtl_fe_create failed: %ld\n", PTR_ERR(ni->fe));
		return PTR_ERR(ni->fe);
	}

	platform_set_drvdata(pdev, ni);
	ret = rtl_ni_ports_register(ni);
	if (ret) {
		dev_err(dev, "rtl_ni_ports_register failed: %d\n", ret);
		rtl_fe_destroy(ni->fe);
		return ret;
	}

	rtl_ni_mib_init(ni);
	dev_info(dev, "rtl_ni_probe succeeded\n");
	/* CU WiFi-NE (Taurus): publish NI device to WiFi identity glue. */
	if (IS_ENABLED(CONFIG_RTL9617C_WIFI_GLUE))
		taurus_wifi_publish(dev);
	return 0;
}

static void rtl_ni_remove(struct platform_device *pdev)
{
	struct rtl9617c_ni *ni = platform_get_drvdata(pdev);

	if (IS_ENABLED(CONFIG_RTL9617C_WIFI_GLUE))
		taurus_wifi_withdraw(&pdev->dev);
	rtl_ni_mib_exit(ni);
	rtl_ni_ports_unregister(ni);
	rtl_fe_destroy(ni->fe);
	hrtimer_cancel(&ni->timer);
}

static const struct of_device_id rtl_ni_of_match[] = {
	{ .compatible = "realtek,rtl9617c-ni" },
	{ }
};
MODULE_DEVICE_TABLE(of, rtl_ni_of_match);

static struct platform_driver rtl_ni_driver = {
	.probe = rtl_ni_probe,
	.remove = rtl_ni_remove,
	.driver = {
		.name = "rtl9617c-ni",
		.of_match_table = rtl_ni_of_match,
	},
};
module_platform_driver(rtl_ni_driver);

MODULE_DESCRIPTION("Realtek RTL9617C network interface driver");
MODULE_LICENSE("GPL");
