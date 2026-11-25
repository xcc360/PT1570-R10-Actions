#!/bin/bash
# Inject experimental PT1570-R10 rtw89 board DTS + profile into refactor source tree.
# Called from workflow with: bash apply-r10-rtw89-exp.sh
# Env: GITHUB_WORKSPACE (assets root), PWD = wrt (source root)
set -e

# Prefer ASSET_DIR from the unified workflow; otherwise derive from script
# location so both the legacy root layout and boards/pt1570-r10/ work.
ASSETS="${ASSET_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$(pwd)"
DTS_DIR="$SRC/target/linux/rtl9617c/dts"
IMG_DIR="$SRC/target/linux/rtl9617c/image"
PLAT="$SRC/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh"

echo "=== apply-r10-rtw89-exp.sh ==="
echo "assets=$ASSETS src=$SRC"

# --- sanity: refactor baseline markers (old built-in OR new AP-firmware split) ---
[ -f "$DTS_DIR/rtk-taurus.dtsi" ] || { echo "ERROR: rtk-taurus.dtsi missing (not refactor baseline)" >&2; exit 1; }
if [ -f "$SRC/package/firmware/rtw89-ap-firmware/Makefile" ]; then
  echo "  baseline: rtw89 AP-firmware split (>= 299da19e2ea6)"
  grep -q 'pcie0_port:' "$DTS_DIR/rtk-taurus.dtsi" \
    || { echo "ERROR: pcie0_port missing (baseline older than 2df200550b73)" >&2; exit 1; }
elif [ -f "$SRC/target/linux/rtl9617c/patches-6.18/740-wifi-rtw89-8192xb.patch" ]; then
  echo "  baseline: legacy built-in rtw89 (pre-299da19e2ea6)"
else
  echo "ERROR: no rtw89 baseline marker found (source too old)" >&2; exit 1
fi

# --- 1) inject DTS ---
cp -f "$ASSETS/board/dts/rtl9617c-pt1570-r10-rtw89.dts" "$DTS_DIR/rtl9617c-pt1570-r10-rtw89.dts"
echo "  injected DTS"

# --- 2) inject device profile before final BuildImage line ---
PROFILE_INC="$ASSETS/board/devices/pt1570-r10-rtw89.mk.inc"
if ! grep -q 'youhua_pt1570_r10_rtw89_exp' "$IMG_DIR/Makefile"; then
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
if 'youhua,pt1570-r10-rtw89-exp' in s:
    print("  platform.sh already whitelisted")
    sys.exit(0)
# First fallback "*)" -> check_image arm; second -> do_upgrade arm
i1=s.find('\t*)\n')
if i1 < 0:
    print("ERROR: platform.sh fallback arm not found", file=sys.stderr); sys.exit(1)
s=s[:i1] + '\tyouhua,pt1570-r10-rtw89-exp)\n\t\tfit_check_image "$1"\n\t\treturn $?\n\t\t;;\n' + s[i1:]
i2=s.find('\t*)\n', i1 + 200)
if i2 < 0:
    print("ERROR: platform.sh 2nd fallback arm not found", file=sys.stderr); sys.exit(1)
s=s[:i2] + '\tyouhua,pt1570-r10-rtw89-exp)\n\t\tfit_do_upgrade "$1"\n\t\t;;\n' + s[i2:]
open(p,'w', encoding='utf-8', newline='\n').write(s)
print("  whitelisted board in platform.sh")
PY

# --- 4) inject wireless overlay into rootfs files/ ---
# OpenWrt copies <source>/files/ into the rootfs; place standard mac80211 config there
# so both radios come up as AP with mainline rtw89.
mkdir -p "$SRC/files/etc/config"
cp -f "$ASSETS/files-exp/etc/config/wireless" "$SRC/files/etc/config/wireless"
echo "  injected wireless overlay"

# --- 5) verify injection landed ---
grep -q 'youhua,pt1570-r10-rtw89-exp' "$PLAT" || { echo "ERROR: platform.sh whitelist failed" >&2; exit 1; }
grep -q 'DEVICE_DTS := rtl9617c-pt1570-r10-rtw89' "$IMG_DIR/Makefile" || { echo "ERROR: profile injection failed" >&2; exit 1; }
[ -f "$DTS_DIR/rtl9617c-pt1570-r10-rtw89.dts" ] || { echo "ERROR: DTS injection failed" >&2; exit 1; }
grep -q 'deviation = <0xffffd120>' "$DTS_DIR/rtl9617c-pt1570-r10-rtw89.dts" \
  || { echo "ERROR: thermal deviation not fixed (boot-shutdown risk)" >&2; exit 1; }
! grep -q 'deviation = <0xfffcd120>' "$DTS_DIR/rtl9617c-pt1570-r10-rtw89.dts" \
  || { echo "ERROR: fatal thermal value still present" >&2; exit 1; }
grep -q "path 'soc/f4325000.pcie" "$SRC/files/etc/config/wireless" \
  || { echo "ERROR: wireless overlay injection failed" >&2; exit 1; }
echo "  all injections verified"
