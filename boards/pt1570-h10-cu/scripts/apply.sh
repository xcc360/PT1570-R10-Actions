#!/bin/bash
# Inject experimental PT1570-H10-CU rtw89 board DTS + profile into refactor source tree.
# Called from workflow with: bash apply-h10-cu-rtw89-exp.sh
# Env: ASSET_DIR (board assets root), PWD = wrt (source root)
set -e

ASSETS="${ASSET_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$(pwd)"
DTS_DIR="$SRC/target/linux/rtl9617c/dts"
IMG_DIR="$SRC/target/linux/rtl9617c/image"
PLAT="$SRC/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh"

echo "=== apply-h10-cu-rtw89-exp.sh ==="
echo "assets=$ASSETS src=$SRC"

# --- sanity: refactor HEAD baseline markers (run28) ---
# 741/742 kernel patches targeted the old in-tree/740-patched rtw89 driver.
# On this baseline rtw89 lives in mac80211 backports and the 8192XB chip ops
# already program AXIDMA in rtw8192xb_pwr_on_func(); legacy patches are NOT
# injected. The AP firmware closes the old C2H/SWSI gaps.
[ -f "$DTS_DIR/rtk-taurus.dtsi" ] \
  || { echo "ERROR: rtk-taurus.dtsi missing (not refactor baseline)" >&2; exit 1; }
[ -f "$SRC/package/kernel/mac80211/patches/rtl/100-wifi-rtw89-ap-firmware-variant.patch" ] \
  || { echo "ERROR: rtw89 AP firmware variant patch missing (baseline too old)" >&2; exit 1; }
[ -f "$SRC/package/kernel/mac80211/patches/rtl/103-wifi-rtw89-add-8192xbe.patch" ] \
  || { echo "ERROR: rtw89 8192XB backports patch missing (baseline too old)" >&2; exit 1; }
[ -f "$SRC/package/firmware/rtw89-ap-firmware/Makefile" ] \
  || { echo "ERROR: rtw89-ap-firmware package missing (baseline too old)" >&2; exit 1; }
echo "  refactor HEAD rtw89 backports baseline verified"

# --- 0a) force hostapd 802.11ac/ax build switches ---
# CONFIG_DRIVER_11AC_SUPPORT / 11AX_SUPPORT are invisible bool symbols in
# package/network/services/hostapd/Config.in (no prompt, "default n"). Values
# placed in the top-level .config are ignored by `make defconfig`, so wpad-openssl
# silently rejects every ieee80211ac/ieee80211ax/he_* option and 5G can only
# come up in HT40. Patch the Kconfig defaults so defconfig keeps them =y.
python3 - "$SRC/package/network/services/hostapd/Config.in" <<'PY'
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding='utf-8')
for sym in ('DRIVER_11AC_SUPPORT', 'DRIVER_11AX_SUPPORT'):
    old = 'config %s\n\tbool\n\tdefault n' % sym
    new = 'config %s\n\tbool\n\tdefault y' % sym
    if old in s:
        s = s.replace(old, new, 1)
    elif new not in s:
        raise SystemExit('ERROR: cannot patch hostapd %s default' % sym)
p.write_text(s, encoding='utf-8', newline='\n')
print('  forced hostapd CONFIG_DRIVER_11AC_SUPPORT/11AX_SUPPORT defaults to y')
PY

# --- 0) install fallback rtw89 firmware ---
# The refactor HEAD driver requests rtw89/rtw8852c_ap_fw.bin and
# rtw89/rtw8192xb_ap_fw.bin from the rtw89-ap-firmware packages (selected in
# Config.txt / DEVICE_PACKAGES). The cut-U2 NIC images below are kept only as
# an early/fallback blob for the non-AP variant; they are baked into the
# kernel alongside regulatory.db and do not conflict with the AP firmware.
#
# IMPORTANT (run28 baseline): these blobs must NOT live under
# target/linux/rtl9617c/base-files/lib/firmware -- the refactor HEAD already
# ships standalone wireless-regdb / rtl8852ce-firmware packages that own
# lib/firmware/regulatory.db and lib/firmware/rtw89/rtw8852c_fw.bin. Placing
# the same paths in base-files makes apk abort with "trying to overwrite ...
# owned by base-files" (seen in H10 run18). Use a non-packaged staging dir
# that only CONFIG_EXTRA_FIRMWARE reads at kernel-build time.
FW_ASSETS="$ASSETS/firmware"
FW_STAGE="$SRC/target/linux/rtl9617c/embedded-firmware"
FW_RT_DIR="$FW_STAGE/rtw89"
mkdir -p "$FW_RT_DIR"
cp -f "$FW_ASSETS/rtw8852c_fw.bin" "$FW_RT_DIR/rtw8852c_fw.bin"
cp -f "$FW_ASSETS/rtw8192xb_fw.bin" "$FW_RT_DIR/rtw8192xb_fw.bin"

# --- 0b) regulatory database (needed for 5G AP channels) ---
# cfg80211 loads regulatory.db in an initcall that runs just BEFORE rootfs is
# mounted on this FIT/UBI setup (dmesg: load fails -2 at 13.89s, rootfs mounts
# at 13.91s). Without it the regdomain stays country 00 where every 5G channel
# is NO-IR, so hostapd refuses to start AP ("Primary frequency not allowed").
# Bake both files into the kernel via CONFIG_EXTRA_FIRMWARE (same trick used for
# the rtw89 firmwares) so request_firmware finds them before rootfs is ready.
# NOTE: CONFIG_EXTRA_FIRMWARE_DIR is $FW_STAGE (a non-packaged staging dir),
# and the embedded name is the bare string in EXTRA_FIRMWARE, so regulatory.db
# must be placed directly under $FW_STAGE while rtw89 firmwares stay under
# $FW_STAGE/rtw89. request_firmware asks for bare "regulatory.db" /
# "regulatory.db.p7s". Keeping this out of base-files avoids the apk conflict
# with the upstream wireless-regdb / rtl8852ce-firmware packages.
FW_REG_DIR="$FW_STAGE"
mkdir -p "$FW_REG_DIR"
cp -f "$FW_ASSETS/regulatory.db" "$FW_REG_DIR/regulatory.db"
cp -f "$FW_ASSETS/regulatory.db.p7s" "$FW_REG_DIR/regulatory.db.p7s"
[ -s "$FW_REG_DIR/regulatory.db" ] || { echo "ERROR: regulatory.db missing" >&2; exit 1; }
python3 - "$FW_RT_DIR" <<'PY'
import pathlib
import struct
import sys

d = pathlib.Path(sys.argv[1])
expected = {'rtw8852c_fw.bin': 0x88520202, 'rtw8192xb_fw.bin': 0x81920102}

def fw_suits(data):
    # mainline rtw89 expects an MFW container (sig 0xff) so it can locate the
    # firmware suits and the trailing element table; wrapped U2 images use it.
    if data[0] == 0xff:
        suits = []
        for i in range(data[1]):
            cv, typ, mp, rsvd, shift, size, rsvd2 = struct.unpack_from(
                '<BBBBII4s', data, 16 + 16 * i)
            if typ == 1 and not mp:
                suits.append(data[shift:shift + size])
        if not suits:
            raise SystemExit('ERROR: MFW container has no normal firmware suit')
        return suits
    return [data]

for name, want in expected.items():
    p = d / name
    data = p.read_bytes()
    suits = fw_suits(data)
    for payload in suits:
        if len(payload) < 4:
            raise SystemExit('ERROR: %s payload is empty' % name)
        got = struct.unpack('<I', payload[:4])[0]
        if got != want:
            raise SystemExit('ERROR: %s chip/cut mismatch: got 0x%08x, want 0x%08x' % (name, got, want))
    fmt = 'MFW' if data[0] == 0xff else 'legacy'
    print('  verified %s %s chip/cut 0x%08x (%d bytes, %d suits)'
          % (name, fmt, want, len(data), len(suits)))
PY

# --- 1) inject DTS ---
cp -f "$ASSETS/board/dts/rtl9617c-pt1570-h10-cu-rtw89.dts" "$DTS_DIR/rtl9617c-pt1570-h10-cu-rtw89.dts"
echo "  injected DTS"

# --- 2) inject device profile before final BuildImage line ---
PROFILE_INC="$ASSETS/board/devices/device.mk.inc"
if ! grep -q 'youhua_pt1570_h10_cu_rtw89_exp' "$IMG_DIR/Makefile"; then
  awk -v inc="$PROFILE_INC" '
    /^\$\(eval \$\(call BuildImage\)\)/ {
      while ((getline line < inc) > 0) print line
      close(inc)
    }
    { print }
  ' "$IMG_DIR/Makefile" > "$IMG_DIR/Makefile.new"
  mv -f "$IMG_DIR/Makefile.new" "$IMG_DIR/Makefile"
  echo "  injected device profile"
fi

# --- 3) whitelist board in platform.sh (both case blocks) ---
python3 - "$PLAT" <<'PY'
import sys
p=sys.argv[1]
s=open(p, encoding='utf-8').read()
if 'youhua,pt1570-h10-cu-rtw89-exp' in s:
    print("  platform.sh already whitelisted")
    sys.exit(0)
# First fallback "*)" -> check_image arm; second -> do_upgrade arm
i1=s.find('\t*)\n')
if i1 < 0:
    print("ERROR: platform.sh fallback arm not found", file=sys.stderr); sys.exit(1)
s=s[:i1] + '\tyouhua,pt1570-h10-cu-rtw89-exp)\n\t\tfit_check_image "$1"\n\t\treturn $?\n\t\t;;\n' + s[i1:]
i2=s.find('\t*)\n', i1 + 200)
if i2 < 0:
    print("ERROR: platform.sh 2nd fallback arm not found", file=sys.stderr); sys.exit(1)
s=s[:i2] + '\tyouhua,pt1570-h10-cu-rtw89-exp)\n\t\tfit_do_upgrade "$1"\n\t\t;;\n' + s[i2:]
open(p,'w', encoding='utf-8', newline='\n').write(s)
print("  whitelisted board in platform.sh")
PY

# --- 4a) inject apk repository signing keys (OpenWrt snapshot + ImmortalWrt) ---
# Both keyrings are baked so the image trusts either official OpenWrt snapshot
# feeds or ImmortalWrt 25.12 mirrors; see boards/<board>/files/etc/apk/keys/.
KEYS_SRC="$ASSETS/files/etc/apk/keys"
KEYS_DST="$SRC/files/etc/apk/keys"
mkdir -p "$KEYS_DST"
cp -f "$KEYS_SRC"/*.pem "$KEYS_DST"/
for k in openwrt-snapshots.pem immortalwrt-25.12.pem; do
  [ -s "$KEYS_DST/$k" ] || { echo "ERROR: apk key $k not injected" >&2; exit 1; }
done
echo "  injected 2 apk keys (openwrt-snapshots + immortalwrt-25.12)"

# --- 4) inject wireless overlay into rootfs files/ ---
# OpenWrt copies <source>/files/ into the rootfs; place standard mac80211 config there
# so both radios come up as AP with mainline rtw89.
mkdir -p "$SRC/files/etc/config"
cp -f "$ASSETS/files/etc/config/wireless" "$SRC/files/etc/config/wireless"
echo "  injected wireless overlay"

# --- 4b) register board in board.d so preinit initializes LAN/PON ---
python3 - "$SRC" <<'PY'
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
board = 'youhua,pt1570-h10-cu-rtw89-exp'
base = src / 'target/linux/rtl9617c/base-files/etc'

p = base / 'board.d/02_network'
s = p.read_text(encoding='utf-8')
if board not in s:
    arm = ('\t%s)\n'
           '\t\tucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4" "pon0"\n'
           '\t\t;;\n') % board
    i = s.find('\t*)\n')
    if i < 0:
        raise SystemExit('ERROR: 02_network fallback arm not found')
    p.write_text(s[:i] + arm + s[i:], encoding='utf-8', newline='\n')

p = base / 'board.d/01_leds'
s = p.read_text(encoding='utf-8')
if board not in s:
    arm = ('\t%s)\n'
           '\t    ucidef_set_led_netdev "wan" "WAN" "LED_PPP_G" "pppoe-wan" "link"\n'
           '\t    ucidef_set_led_netdev "lan2" "LAN2" "LED_EPHY1" "lan2"\n'
           '\t    ucidef_set_led_netdev "lan3" "LAN3" "LED_EPHY2" "lan3"\n'
           '\t    ucidef_set_led_netdev "lan4" "LAN4" "LED_EPHY3" "lan4"\n'
           '\t\t;;\n') % board
    # Upstream 01_leds uses no leading tab on case labels; match line start
    # without assuming indentation.
    marker = 'youhua,pt1500-h10-2p5g)'
    i = s.find(marker)
    if i < 0:
        raise SystemExit('ERROR: 01_leds youhua case not found')
    i = s.rfind('\n', 0, i) + 1
    p.write_text(s[:i] + arm + s[i:], encoding='utf-8', newline='\n')
print("  registered board in board.d/01_leds and 02_network")
PY

# --- 4c) bake firmware into kernel: built-in rtw89 probes before rootfs mount ---
KCFG="$SRC/target/linux/rtl9617c/config-6.18"
FWDIR="$FW_STAGE"
[ -s "$FWDIR/rtw89/rtw8852c_fw.bin" ] || { echo "ERROR: 8852C firmware missing" >&2; exit 1; }
[ -s "$FWDIR/rtw89/rtw8192xb_fw.bin" ] || { echo "ERROR: 8192XB firmware missing" >&2; exit 1; }
sed -i '/^CONFIG_EXTRA_FIRMWARE=/d; /^CONFIG_EXTRA_FIRMWARE_DIR=/d' "$KCFG"
{
  echo 'CONFIG_EXTRA_FIRMWARE="rtw89/rtw8852c_fw.bin rtw89/rtw8192xb_fw.bin regulatory.db regulatory.db.p7s"'
  echo "CONFIG_EXTRA_FIRMWARE_DIR=\"$FWDIR\""
} >> "$KCFG"
echo "  baked rtw89 firmware into kernel config"

# --- 5) verify injection landed ---
grep -q 'youhua,pt1570-h10-cu-rtw89-exp' "$PLAT" || { echo "ERROR: platform.sh whitelist failed" >&2; exit 1; }
grep -q 'DEVICE_DTS := rtl9617c-pt1570-h10-cu-rtw89' "$IMG_DIR/Makefile" || { echo "ERROR: profile injection failed" >&2; exit 1; }
[ -f "$DTS_DIR/rtl9617c-pt1570-h10-cu-rtw89.dts" ] || { echo "ERROR: DTS injection failed" >&2; exit 1; }
grep -q "path 'soc/f4325000.pcie" "$SRC/files/etc/config/wireless" \
  || { echo "ERROR: wireless overlay injection failed" >&2; exit 1; }
grep -q 'youhua,pt1570-h10-cu-rtw89-exp' "$SRC/target/linux/rtl9617c/base-files/etc/board.d/02_network" \
  || { echo "ERROR: board.d registration failed" >&2; exit 1; }
grep -q 'CONFIG_EXTRA_FIRMWARE="rtw89/rtw8852c_fw.bin' "$KCFG" \
  || { echo "ERROR: kernel firmware embedding failed" >&2; exit 1; }
grep -q 'CONFIG_EXTRA_FIRMWARE=.*regulatory.db' "$KCFG" \
  || { echo "ERROR: regulatory.db not baked into kernel" >&2; exit 1; }
DTS_ASSET="$ASSETS/board/dts/rtl9617c-pt1570-h10-cu-rtw89.dts"
grep -q 'realtek,ap-firmware' "$DTS_ASSET" \
  || { echo "ERROR: 8852C AP firmware DT property missing" >&2; exit 1; }
grep -q 'realtek,rfe-type = <54>' "$DTS_ASSET" \
  || { echo "ERROR: RFE54 DT property missing" >&2; exit 1; }
echo "  all injections verified"
