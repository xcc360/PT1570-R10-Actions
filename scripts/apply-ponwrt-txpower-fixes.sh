#!/bin/bash
# PT1570-R10：移植 PonWRT-TYFZA1 v0.8.5-beta 的 WiFi 发射功率 ucode 修复。
#
# 来源：port/openwrt-patches/100-wifi-ucode-txpower.patch（release notes
# "修复发射功率 0 dBm 设置、设置失败上报及未知功率显示"）。
#
#   * wifi-scripts 的 mac80211.sh 用 `if (config.txpower)` 判断，显式 0 dBm
#     会被当成「未设置」；改为 `!= null`。
#   * `iw phy set txpower` 的返回值被丢弃，失败时静默；改为失败即
#     setup_failed('TXPOWER_FAILED') + return false，并由调用点检查。
#   * setup_phy 末尾补 return true，调用点 `if (!setup_phy(...)) return 1;`。
#
# 幂等：锚点已修复则跳过；找不到 wifi-scripts 只告警、不阻断编译
#（不同 OpenWrt/ImmortalWrt 快照的文件位置可能不同）。
set -euo pipefail

WRT="${WRT:-${GITHUB_WORKSPACE:-.}/wrt}"
python3 - "$WRT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
globs = [
    'package/network/config/wifi-scripts/files-ucode/lib/netifd/wireless/mac80211.sh',
    'feeds/*/package/network/config/wifi-scripts/files-ucode/lib/netifd/wireless/mac80211.sh',
]
target = None
for g in globs:
    found = sorted(root.glob(g))
    if found:
        target = found[0]
        break
if target is None:
    print('PONWRT_TXPOWER_FIX=SKIP (wifi-scripts mac80211.sh not found under %s)' % root)
    raise SystemExit(0)

text = target.read_text('utf-8')
subs = [
    ('\tif (config.txpower)\n',
     '\tif (config.txpower != null)\n',
     'txpower-null'),
    ('\tsystem(`iw phy ${phy} set txpower ${config.txpower}`);\n',
     '\tif (system(`iw phy ${phy} set txpower ${config.txpower}`)) {\n'
     '\t\tnetifd.setup_failed(\'TXPOWER_FAILED\');\n'
     '\t\treturn false;\n'
     '\t}\n',
     'txpower-fail'),
    ('\tsystem(`iw phy ${phy} set rts ${config.rts}`);\n',
     '\tsystem(`iw phy ${phy} set rts ${config.rts}`);\n'
     '\treturn true;\n',
     'setup-return'),
    ('\tsetup_phy(data.phy, data.config, data.data);\n',
     '\tif (!setup_phy(data.phy, data.config, data.data))\n'
     '\t\treturn 1;\n',
     'setup-check'),
]

applied = 0
already = 0
missing = 0
for old, new, tag in subs:
    if new in text:
        already += 1
        print('  %-16s already applied' % tag)
        continue
    n = text.count(old)
    if n != 1:
        missing += 1
        print('  %-16s SKIP (anchor count=%d, upstream layout differs)' % (tag, n))
        continue
    text = text.replace(old, new, 1)
    applied += 1
    print('  %-16s applied' % tag)

if applied:
    target.write_text(text, encoding='utf-8', newline='\n')

state = 'OK' if (applied + already) == len(subs) else ('NOOP' if missing == len(subs) else 'PARTIAL')
print('PONWRT_TXPOWER_FIX=%s applied=%d already=%d skipped=%d file=%s'
      % (state, applied, already, missing, target))
PY
