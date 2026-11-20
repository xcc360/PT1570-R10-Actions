# SPDX-License-Identifier: GPL-2.0-only

ccflags-y += -I$(src)

obj-$(CONFIG_RTL9617C_NI) += rtl9617c-ni.o
rtl9617c-ni-y := ni/ni_main.o ni/ni_port.o ni/ni_dma.o ni/ni_qm.o \
		 ni/ni_p6.o ni/ni_mib.o ni/ni_api.o \
		 rtl9617c-wifi.o
rtl9617c-ni-$(CONFIG_RTL9617C_FE) += fe/fe_main.o fe/fe_hw.o fe/fe_itu.o \
				     fe/fe_bridge.o

obj-$(CONFIG_RTL9617C_BOSA) += rtl9617c-bosa.o
rtl9617c-bosa-y := bosa/bosa.o

obj-$(CONFIG_RTL9617C_PON) += rtl9617c-pon.o
rtl9617c-pon-y := pon/pon_main.o pon/pon_link.o pon/pon_serdes.o \
		  pon/pon_debug.o pon/pon_debug_events.o pon/pon_debug_regs.o \
		  pon/epon/epon.o pon/epon/epon_crypto.o pon/epon/epon_mib.o \
		  pon/epon/epon_sla.o pon/epon/epon_holdover.o pon/epon/mpcp.o \
		  pon/epon/mpcp_state.o pon/epon/oam.o pon/epon/oam_setup.o \
		  pon/epon/data.o \
		  pon/itu/itu.o pon/itu/itu_puc.o pon/itu/gpon.o pon/itu/xgpon.o \
		  pon/itu/xgpon_recovery.o pon/itu/xgpon_health.o \
		  pon/itu/omci.o pon/itu/omci_channel.o \
		  pon/data/pdc.o pon/data/puc.o pon/data/path.o \
		  pon/data/path_data.o pon/data/vlan.o
