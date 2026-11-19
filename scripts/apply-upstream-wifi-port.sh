#!/bin/bash
# PT1570-R10 WiFi：在「已验证的单 PE1 参考驱动」上，定向移植上游 0.8.4 的
# 扫描/站点 RSSI 上报修复（LeoooChen/PonWRT-TYFZA1@6077a9a76812 的 single-PE
# 兼容子集），以及 0.8.5 的 RA 信号解析结构（@f74af178efe5 的 rate.h 子集）。
#
# 边界（违反任一条即 fail，绝不产出可刷固件）：
#   - 只在 overlay-wifi-driver.sh 之后执行：锚点是我们的参考版驱动，不是上游现场版。
#   - 禁止引入双 PE：pe-core.c 不存在、Makefile 无 pe-core.o、无 rx-geometry WD 保留位。
#   - pe-tx-code.h 必须是 4076-word / md5=7eb49893 的单 PE1 微码，绝不替换。
#   - 不整包覆盖 pe-tx-code.h / monitor.h / pci.c；只按唯一锚点做最小插入。
#   - 幂等：检测标记存在即跳过，重复执行不重复打补丁。
#   - WIFI_PORT=off 时本脚本直接退出，构建行为与现网完全一致。
#
# 用法：WIFI_PORT=scan-rssi|scan-rssi+ra ASSETS=<workspace> WRT=<workspace>/wrt \
#       bash apply-upstream-wifi-port.sh
set -euo pipefail

ASSETS="${ASSETS:-$GITHUB_WORKSPACE}"
WRT="${WRT:-$ASSETS/wrt}"
WIFI_PORT="${WIFI_PORT:-off}"

fail() { echo "::error::WIFI_PORT: $*" >&2; exit 1; }

case "$WIFI_PORT" in
  off) echo "WIFI_PORT=off: upstream wifi port skipped (no behavior change)"; exit 0 ;;
  scan-rssi|scan-rssi+ra) ;;
  *) fail "unknown WIFI_PORT='$WIFI_PORT' (expected off/scan-rssi/scan-rssi+ra)" ;;
esac

DST="$WRT/target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtl_ax_ap"
[ -d "$DST" ] || fail "找不到驱动目录 $DST（overlay 未执行？）"

# ---------- 硬护栏：单 PE1 参考基线 ----------
[ ! -e "$DST/pe-core.c" ] || fail "禁止引入双 PE：检测到 pe-core.c"
! grep -q 'pe-core\.o' "$DST/Makefile" || fail "禁止引入双 PE：Makefile 引用 pe-core.o"
[ "$(md5sum "$DST/pe-tx-code.h" | cut -d' ' -f1)" = 7eb49893f43b897bf03fa82ae2323984 ] \
  || fail "pe-tx-code.h md5 不符（单 PE1 微码被改）"
[ "$(grep -c '0x' "$DST/pe-tx-code.h")" = 4076 ] || fail "pe-tx-code.h 指令数 != 4076"
! grep -q 'RTL_AX_TX_WD_PER_RING' "$DST/rx-geometry.h" || fail "带入 0.8.3 WD 保留改动"

echo "=== upstream single-PE WiFi port: $WIFI_PORT ==="
echo "guard: PE1/4076words/md5=7eb49893 OK, no pe-core.c, no WD-retain"

python3 - "$DST" "$WIFI_PORT" <<'PY'
import pathlib, sys

DST = pathlib.Path(sys.argv[1])
PORT = sys.argv[2]
MARK_SCAN = 'RTL_AX_AP_SCAN_H'          # scan.h include guard / presence marker
MARK_RA   = 'struct rtl_ax_ra_rssi {'    # B2 marker in rate.h

def load(name):
    return DST / name

def replace_exact(path, old, new, label, marker):
    """幂等：marker（插入内容里的唯一串）已存在即跳过；否则锚点必须恰好 1 次。
    marker 与 old/new 分离，避免 new 含 old 时幂等检测失效导致重复插入。"""
    p = load(path)
    text = p.read_text(encoding='utf-8')
    if marker in text:
        print('%s: %s already applied, skip' % (path, label))
        return
    c = text.count(old)
    if c != 1:
        raise SystemExit('ERROR: %s 中锚点[%s]出现 %d 次（期望 1）:\n%r'
                         % (path, label, c, old[:120]))
    p.write_text(text.replace(old, new, 1), encoding='utf-8', newline='\n')
    print('%s: %s applied' % (path, label))

# ============ B1: scan / station RSSI (6077a9a single-PE subset) ============
scan_h = r'''/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef RTL_AX_AP_SCAN_H
#define RTL_AX_AP_SCAN_H

/* Ported from PonWRT-TYFZA1 6077a9a (0.8.4) single-PE subset.
 * MAC PPDU header precedes the PHY header, even for unassociated BSSes.
 * RPL in PHY IE0/1 is U8.1 with a -110 dBm origin (not header TD RSSI). */
static inline int rtl_ax_scan_rpl(const u8 *data, unsigned int bytes)
{
	u32 first, second, users, offset;
	const u8 *phy;
	unsigned int length, id, page;

	if (bytes < 8) return -EINVAL;
	first = get_unaligned_le32(data);
	second = get_unaligned_le32(data + 4);
	users = first & 15;
	if (users > 8) return -EINVAL;
	offset = 8 + ((users + 1) & ~1U) * 4 +
		(first & BIT(29) ? 96 : 0) + ((second >> 16) & 255) * 8;
	if (offset > bytes || bytes - offset < 8) return -EINVAL;
	phy = data + offset;
	length = phy[1] * 8;
	page = phy[0] & 31;
	if (!(phy[0] & BIT(7)) || length < 24 || length > bytes - offset)
		return -EINVAL;
	if (page < 11 || page > 15) return -EINVAL;
	id = phy[8] & 31;
	if (id != (page == 11 ? 0 : 1) || (id == 1 && length < 40)) return -EINVAL;
	return phy[9];
}

static inline bool rtl_ax_scan_ppdu_match(u32 frame0, u32 frame1,
	u32 report0, u32 report1)
{
	/* Original C/XB WD: BB22, PPDU type0:3/count4:6, rate16:24,
	 * GI25:27 and BW29:31. Never reuse an RSSI from a different PPDU. */
	return !((frame0 ^ report0) & BIT(22)) &&
		!((frame1 ^ report1) & 0xefff007f);
}
#endif
'''

# -- scan.h 新文件 --
sh = load('scan.h')
if not sh.exists():
    sh.write_text(scan_h, encoding='utf-8', newline='\n')
    print('scan.h: created')
elif MARK_SCAN in sh.read_text(encoding='utf-8'):
    print('scan.h: already present, skip')
else:
    raise SystemExit('ERROR: scan.h 存在但不是本补丁的版本')

# -- pci.c --
replace_exact('pci.c',
    '#include "rate.h"\n#include "port0.h"',
    '#include "rate.h"\n#include "scan.h"\n#include "port0.h"',
    'include scan.h',
    '#include "scan.h"')

replace_exact('pci.c',
    '\tbool ra_sampling;\n\tu64 station_added, station_removed;',
    '\tbool ra_sampling;\n'
    '\t/* Ported scan-RSSI decode state (6077a9a single-PE subset). */\n'
    '\tbool scanning;\n'
    '\tstruct sk_buff *scan_pending;\n'
    '\tu32 scan_word0, scan_word1;\n'
    '\tu64 scan_received_ns;\n'
    '\tu64 scan_matched, scan_unmatched;\n'
    '\tu8 scan_last_bssid[6], scan_last_rpl;\n'
    '\tu64 station_added, station_removed;',
    'struct scan fields',
    'Ported scan-RSSI decode state (6077a9a single-PE subset)')

replace_exact('pci.c',
    'static int rtl_ax_monitor_receive(struct rtl_ax_ap *radio,\n'
    '\tconst struct rtl_ax_rx_packet *packet);\n',
    'static int rtl_ax_monitor_receive(struct rtl_ax_ap *radio,\n'
    '\tconst struct rtl_ax_rx_packet *packet);\n'
    'static void rtl_ax_scan_complete_frame(struct rtl_ax_ap *radio,\n'
    '\tconst struct rtl_ax_rx_packet *report);\n',
    'scan_complete_frame forward decl',
    'static void rtl_ax_scan_complete_frame(struct rtl_ax_ap *radio,')

replace_exact('pci.c',
    '\tif (packet->type == 0 && READ_ONCE(radio->monitor_started))\n'
    '\t\treturn rtl_ax_monitor_receive(radio, packet);\n'
    '\tif (packet->type == 1) {',
    '\tif (packet->type == 0 && READ_ONCE(radio->monitor_started)) {\n'
    '\t\trtl_ax_scan_complete_frame(radio, NULL);\n'
    '\t\treturn rtl_ax_monitor_receive(radio, packet);\n'
    '\t}\n'
    '\tif (packet->type == 1) {',
    'type0 scan flush',
    'rtl_ax_scan_complete_frame(radio, NULL);\n\t\treturn rtl_ax_monitor_receive')

replace_exact('pci.c',
    '\t\tunsigned int i;\n\n'
    '\t\tif (!(rtl_ax_ap_read32(packet->descriptor) & BIT(23))) return 0;\n'
    '\t\tret = rtl_ax_ppdu_signal(packet->payload, packet->bytes, signals);',
    '\t\tunsigned int i;\n\n'
    '\t\trtl_ax_scan_complete_frame(radio, packet);\n'
    '\t\tif (!(rtl_ax_ap_read32(packet->descriptor) & BIT(23))) return 0;\n'
    '\t\tret = rtl_ax_ppdu_signal(packet->payload, packet->bytes, signals);',
    'type1 scan match',
    'rtl_ax_scan_complete_frame(radio, packet);')

replace_exact('pci.c',
    '\trtl_ax_rx_close(radio->rx);\n'
    '\tret = rtl_ax_dfs_stop_locked(radio);\n'
    '\t/* CAC and a failed detector configuration both keep the MAC quiet. */',
    '\trtl_ax_rx_close(radio->rx);\n'
    '\tret = rtl_ax_dfs_stop_locked(radio);\n'
    '\trtl_ax_scan_complete_frame(radio, NULL);\n'
    '\t/* CAC and a failed detector configuration both keep the MAC quiet. */',
    'CAC scan flush',
    'rtl_ax_dfs_stop_locked(radio);\n\trtl_ax_scan_complete_frame(radio, NULL);')

replace_exact('pci.c',
    '\tstruct rtl_ax_ap *radio = dev_get_drvdata(dev);\n'
    '\tunsigned int bytes = 0, i;\n'
    '\tunsigned long flags;\n\n'
    '\tspin_lock_irqsave(&radio->command_lock, flags);\n'
    '\tfor (i = 1; i < 128 && bytes < PAGE_SIZE - 180; i++) {',
    '\tstruct rtl_ax_ap *radio = dev_get_drvdata(dev);\n'
    '\tunsigned int bytes = 0, i;\n'
    '\tunsigned long flags;\n\n'
    '\tbytes += sysfs_emit_at(buffer, bytes, "scan_RSSI_matched=%llu unmatched=%llu\\n",\n'
    '\t\tradio->scan_matched, radio->scan_unmatched);\n'
    '\tbytes += sysfs_emit_at(buffer, bytes, "scan_last_BSSID=%pM RPL_U8_1=%u signal_dBm=%d\\n",\n'
    '\t\tradio->scan_last_bssid, radio->scan_last_rpl,\n'
    '\t\t(int)(radio->scan_last_rpl >> 1) - 110);\n'
    '\tspin_lock_irqsave(&radio->command_lock, flags);\n'
    '\tfor (i = 1; i < 128 && bytes < PAGE_SIZE - 180; i++) {',
    'radio_ra_show scan stats',
    'scan_RSSI_matched=%llu unmatched=%llu')

# -- monitor.h --
replace_exact('monitor.h',
    '\trtl_ax_rx_close(radio->rx);\n'
    '\tradio->dfs.error = rtl_ax_dfs_stop_locked(radio);',
    '\trtl_ax_rx_close(radio->rx);\n'
    '\trtl_ax_scan_complete_frame(radio, NULL);\n'
    '\tradio->dfs.error = rtl_ax_dfs_stop_locked(radio);',
    'monitor_stop scan flush',
    'rtl_ax_rx_close(radio->rx);\n\trtl_ax_scan_complete_frame(radio, NULL);\n\tradio->dfs.error')

replace_exact('monitor.h',
    '\tmutex_lock(&radio->command_mutex);\n'
    '\trtl_ax_receive_mode(&radio->io, radio->ap_started ? 4 : 0);\n'
    '\tmutex_unlock(&radio->command_mutex);\n'
    '}\n\n'
    'static void rtl_ax_monitor_tx(struct ieee80211_hw *hw,',
    '\tmutex_lock(&radio->command_mutex);\n'
    '\trtl_ax_receive_mode(&radio->io, radio->ap_started && !radio->scanning ? 4 : 0);\n'
    '\tmutex_unlock(&radio->command_mutex);\n'
    '}\n\n'
    'static void rtl_ax_sw_scan_start(struct ieee80211_hw *hw,\n'
    '\tstruct ieee80211_vif *vif, const u8 *mac_addr)\n'
    '{\n'
    '\tstruct rtl_ax_ap *radio = rtl_ax_monitor_radio(hw);\n\n'
    '\tmutex_lock(&radio->command_mutex);\n'
    '\tradio->scanning = true;\n'
    '\t/* Include foreign beacons, not only address-1 matches. */\n'
    '\trtl_ax_update32(&radio->io, 0xce40, BIT(4), BIT(0));\n'
    '\tmutex_unlock(&radio->command_mutex);\n'
    '}\n\n'
    'static void rtl_ax_sw_scan_complete(struct ieee80211_hw *hw,\n'
    '\tstruct ieee80211_vif *vif)\n'
    '{\n'
    '\tstruct rtl_ax_ap *radio = rtl_ax_monitor_radio(hw);\n\n'
    '\tmutex_lock(&radio->command_mutex);\n'
    '\tradio->scanning = false;\n'
    '\trtl_ax_update32(&radio->io, 0xce40, BIT(0) | BIT(4),\n'
    '\t\tBIT(4) | (radio->ra_sampling ? BIT(0) : 0));\n'
    '\trtl_ax_receive_mode(&radio->io, radio->ap_started ? 4 : 0);\n'
    '\tmutex_unlock(&radio->command_mutex);\n'
    '}\n\n'
    'static void rtl_ax_monitor_tx(struct ieee80211_hw *hw,',
    'sw_scan callbacks',
    'rtl_ax_sw_scan_start')

replace_exact('monitor.h',
    '\trtl_ax_update32(&radio->io, 0xce40, BIT(0), 0);\n'
    '\tradio->ra_sampling = false;',
    '\tif (!radio->scanning)\n'
    '\t\trtl_ax_update32(&radio->io, 0xce40, BIT(0), 0);\n'
    '\tradio->ra_sampling = false;',
    'ra_work scan guard',
    'if (!radio->scanning)')

replace_exact('monitor.h',
    '\t.configure_filter = rtl_ax_monitor_filter,\n'
    '\t.add_chanctx = ieee80211_emulate_add_chanctx,',
    '\t.configure_filter = rtl_ax_monitor_filter,\n'
    '\t.sw_scan_start = rtl_ax_sw_scan_start,\n'
    '\t.sw_scan_complete = rtl_ax_sw_scan_complete,\n'
    '\t.add_chanctx = ieee80211_emulate_add_chanctx,',
    'ops.sw_scan callbacks',
    '.sw_scan_start = rtl_ax_sw_scan_start')

replace_exact('monitor.h',
    '};\n\n'
    'static int rtl_ax_monitor_receive(struct rtl_ax_ap *radio,\n'
    '\tconst struct rtl_ax_rx_packet *packet)',
    '};\n\n'
    'static void rtl_ax_scan_complete_frame(struct rtl_ax_ap *radio,\n'
    '\tconst struct rtl_ax_rx_packet *report)\n'
    '{\n'
    '\tstruct sk_buff *skb = radio->scan_pending;\n'
    '\tstruct ieee80211_rx_status *status;\n'
    '\tint rpl = -EINVAL;\n\n'
    '\tif (!skb) return;\n'
    '\tradio->scan_pending = NULL;\n'
    '\t/* Do not match a wrapped PPDU ID after a report-sampling gap. */\n'
    '\tif (report && ktime_get_ns() - radio->scan_received_ns < 20000000 &&\n'
    '\t    !report->crc_error &&\n'
    '\t    (rtl_ax_ap_read32(report->descriptor) & BIT(23)) &&\n'
    '\t    rtl_ax_scan_ppdu_match(radio->scan_word0, radio->scan_word1,\n'
    '\t\trtl_ax_ap_read32(report->descriptor),\n'
    '\t\trtl_ax_ap_read32(report->descriptor + 4)))\n'
    '\t\trpl = rtl_ax_scan_rpl(report->payload, report->bytes);\n'
    '\tstatus = IEEE80211_SKB_RXCB(skb);\n'
    '\tif (rpl >= 0) {\n'
    '\t\tstatus->signal = (rpl >> 1) - 110;\n'
    '\t\tstatus->flag &= ~RX_FLAG_NO_SIGNAL_VAL;\n'
    '\t\tradio->scan_last_rpl = rpl;\n'
    '\t\tmemcpy(radio->scan_last_bssid, skb->data + 16, 6);\n'
    '\t\tradio->scan_matched++;\n'
    '\t} else {\n'
    '\t\t/* Keep unknown samples out of the BSS cache: a zero signal would\n'
    '\t\t * overwrite a real measurement and become -256 in iwinfo. */\n'
    '\t\tstatus->flag |= RX_FLAG_ONLY_MONITOR;\n'
    '\t\tradio->scan_unmatched++;\n'
    '\t}\n'
    '\tieee80211_rx_ni(radio->hw, skb);\n'
    '}\n\n'
    'static int rtl_ax_monitor_receive(struct rtl_ax_ap *radio,\n'
    '\tconst struct rtl_ax_rx_packet *packet)',
    'scan_complete_frame definition',
    'radio->scan_last_bssid, skb->data + 16, 6')

# monitor.h: 本地帧控制用 *(__le16 *)payload，没有 frame_control 变量。
# 这里新增局部变量并以 get_unaligned 读取（与上游一致），供 beacon/probe_resp 判断。
replace_exact('monitor.h',
    '\tu16 rate = (word >> 16) & 0x1ff;\n'
    '\tu8 bandwidth = word >> 29, gi_ltf = (word >> 25) & 7;\n'
    '\tbool profile = READ_ONCE(rtl_ax_datapath_profile);',
    '\tu16 rate = (word >> 16) & 0x1ff;\n'
    '\t__le16 frame_control;\n'
    '\tu8 bandwidth = word >> 29, gi_ltf = (word >> 25) & 7;\n'
    '\tbool profile = READ_ONCE(rtl_ax_datapath_profile);',
    'frame_control decl',
    '__le16 frame_control;')

replace_exact('monitor.h',
    '\tif (packet->bytes < 2 + FCS_LEN)\n'
    '\t\treturn -EINVAL;\n'
    '\t/* Actual hal_parsing_rx_wd_C/XB word1 carries rate16:24,',
    '\tif (packet->bytes < 2 + FCS_LEN)\n'
    '\t\treturn -EINVAL;\n'
    '\tframe_control = get_unaligned((const __le16 *)packet->payload);\n'
    '\t/* Actual hal_parsing_rx_wd_C/XB word1 carries rate16:24,',
    'frame_control init',
    'frame_control = get_unaligned((const __le16 *)packet->payload);')

replace_exact('monitor.h',
    '\tieee80211_rx_ni(radio->hw, skb);\n'
    '\tif (profile)\n'
    '\t\tradio->rx_mac80211_ns += ktime_get_ns() - delivered;',
    '\tif (packet->bytes >= 36 + FCS_LEN && !packet->crc_error &&\n'
    '\t    (ieee80211_is_beacon(frame_control) ||\n'
    '\t     ieee80211_is_probe_resp(frame_control))) {\n'
    '\t\tradio->scan_pending = skb;\n'
    '\t\tradio->scan_word0 = rtl_ax_ap_read32(packet->descriptor);\n'
    '\t\tradio->scan_word1 = rtl_ax_ap_read32(packet->descriptor + 4);\n'
    '\t\tradio->scan_received_ns = ktime_get_ns();\n'
    '\t} else {\n'
    '\t\tieee80211_rx_ni(radio->hw, skb);\n'
    '\t}\n'
    '\tif (profile)\n'
    '\t\tradio->rx_mac80211_ns += ktime_get_ns() - delivered;',
    'beacon/probe_resp scan暂存',
    'radio->scan_pending = skb;')

replace_exact('monitor.h',
    '\tieee80211_hw_set(hw, RX_INCLUDES_FCS);\n'
    '\t/* mac80211 handles BIP and SW_MGMT_TX; RX retains the CCMP IV/MIC. */',
    '\tieee80211_hw_set(hw, RX_INCLUDES_FCS);\n'
    '\tieee80211_hw_set(hw, SIGNAL_DBM);\n'
    '\t/* mac80211 handles BIP and SW_MGMT_TX; RX retains the CCMP IV/MIC. */',
    'SIGNAL_DBM',
    'ieee80211_hw_set(hw, SIGNAL_DBM)')

# ============ B2: RA 信号解析结构 (f74af178 rate.h subset) ============
if PORT == 'scan-rssi+ra':
    rate_h = load('rate.h')
    txt = rate_h.read_text(encoding='utf-8')
    if MARK_RA in txt:
        print('rate.h: RA subset already present, skip')
    else:
        # 保留 struct rtl_ax_phy_signal（本地 rtl_ax_ppdu_signal 仍用），在其后插入新结构/函数
        anchor = 'struct rtl_ax_phy_signal { u8 macid, rssi[3]; };\n'
        c = txt.count(anchor)
        if c != 1:
            raise SystemExit('ERROR: rate.h struct 锚点出现 %d 次（期望 1）' % c)
        ra_block = r'''struct rtl_ax_phy_signal { u8 macid, rssi[3]; };

/* Ported from PonWRT-TYFZA1 f74af178 (0.8.5) rate.h subset: finer PPDU page
 * parsing + moving-average RSSI state. Structures/functions only; RA command
 * restructure (tx.c/pe-core.c coupled) intentionally NOT ported. */
struct rtl_ax_ra_sample { u8 macid, rssi[3], paths; bool beacon; };
struct rtl_ax_ra_rssi {
	u16 ma[2][3], count[2]; /* Data/beacon; overall and independent RF paths. */
	u8 factor[2];
};

static inline void rtl_ax_ra_rssi_init(struct rtl_ax_ra_rssi *state)
{
	memset(state, 0, sizeof(*state));
	state->factor[0] = state->factor[1] = 2;
}

/* Actual halbb_rx_pkt_su_store_in_sta_info: samples are U8.1, MA is sample*16.
 * Each zero MA initializes independently; subtraction rounds before addition. */
static inline void rtl_ax_ra_rssi_sample(struct rtl_ax_ra_rssi *state,
	const struct rtl_ax_ra_sample *sample, u8 rssi[3])
{
	unsigned int kind = sample->beacon, shift = 4 - state->factor[kind], i;

	for (i = 0; i < 3; i++) {
		u16 *ma = &state->ma[kind][i];

		if (i && !(sample->paths & BIT(i - 1))) continue;
		*ma = !*ma ? sample->rssi[i] << 4 :
			*ma + (sample->rssi[i] << shift) - ((*ma << shift) >> 4);
	}
	state->count[kind]++;
	if (!kind) {
		rssi[0] = (state->ma[0][0] + 8) >> 4;
		rssi[1] = state->ma[0][1] >> 4;
		rssi[2] = state->ma[0][2] >> 4;
	}
}

/* halbb_cmn_info_self_update selects the next period's factor, then clears
 * the qualifying PHY-report counts from continuous collection. */
static inline void rtl_ax_ra_rssi_watchdog(struct rtl_ax_ra_rssi *state)
{
	u16 data = state->count[0];

	state->factor[0] = data > 100 ? 4 : data > 20 ? 3 : data > 5 ? 2 : 1;
	state->factor[1] = state->count[1] > 5 ? 2 : 1;
	state->count[0] = state->count[1] = 0;
}

/* Normal halbb_cmn_info_self_update selects data, then beacon RSSI. */
static inline u8 rtl_ax_bb_rssi(const struct rtl_ax_ra_rssi *state)
{
	u8 data = (state->ma[0][0] + 8) >> 4;

	return data ? data : (state->ma[1][0] + 8) >> 4;
}

/* Board hal_handle_rx_buffer -> halbb_physts_parsing -> halbb_cmn_rpt.
 * SU is WD1 PPDU type !=6/9/10; the parser uses only user0's MACID/flags. */
static inline int rtl_ax_ppdu_ra_signal(const u8 *data, unsigned int bytes,
	u8 ppdu_type, bool to_self, struct rtl_ax_ra_sample *sample)
{
	u32 first, second, users, offset, user;
	const u8 *phy;
	u8 average, a, b, type;

	if (!to_self || ppdu_type == 6 || ppdu_type == 9 || ppdu_type == 10) return 0;
	if (bytes < 8) return -EINVAL;
	first = get_unaligned_le32(data); second = get_unaligned_le32(data + 4);
	users = first & 15;
	if (users > 8) return -EINVAL;
	offset = 8 + ((users + 1) & ~1U) * 4 + (first & BIT(29) ? 96 : 0) + ((second >> 16) & 255) * 8;
	if (offset > bytes || bytes - offset < 8) return -EINVAL;
	phy = data + offset;
	if (!(phy[0] & BIT(7)) || phy[1] * 8 != bytes - offset || phy[1] < 1) return -EINVAL;
	type = phy[0] & 31;
	/* halbb_physts_parsing@2c5744: types0..5 and8 clear to-self/user flags. */
	if (!users || type <= 5 || type == 8) return 0;
	user = get_unaligned_le32(data + 8);
	if (!(user & BIT(0)) || !(user & (BIT(1) | BIT(4))) || ((user >> 8) & 255) >= 128) return 0;
	if (phy[1] < 3 || (phy[8] & 31) > 1) return 0;
	if ((phy[8] & 31) == 1 && phy[1] < 5) return 0;
	sample->macid = (user >> 8) & 255;
	sample->beacon = !!(user & BIT(4));
	/* IE0 byte15[7:4], IE1 DWORD0[31:28] are rx_path_en. */
	sample->paths = (phy[8] & 31) ? phy[11] >> 4 : phy[23] >> 4;
	a = sample->paths & BIT(0) ? phy[4] : 0;
	b = sample->paths & BIT(1) ? phy[5] : 0;
	average = (sample->paths & 3) == 3 ? phy[3] : a > b ? a : b;
	sample->rssi[0] = phy[9];
	sample->rssi[1] = a ? phy[9] + a - average : 0;
	sample->rssi[2] = b ? phy[9] + b - average : 0;
	return 1;
}
'''
        rate_h.write_text(txt.replace(anchor, ra_block, 1), encoding='utf-8', newline='\n')
        print('rate.h: RA signal subset applied')

print('UPSTREAM_WIFI_PORT_APPLIED=True (port=%s)' % PORT)
PY

echo "UPSTREAM_WIFI_PORT_SCRIPT_OK=True (port=$WIFI_PORT)"