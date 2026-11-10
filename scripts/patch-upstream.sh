#!/bin/bash
# 修补上游源码树里与本机型相关的缺陷（幂等，可重复执行）。
#
# 用法：
#   ASSETS=<资产目录> WRT=<源码树> bash scripts/patch-upstream.sh
#
# 修两件事：
#   1. package/tyfza1-pon-control/files/tyfza1-factory 的 factory_blob() 参数错位：
#      函数签名是 factory_blob <offset> <size> <dest>，但结尾写的是
#        mv "$tmp" "$2"
#      $2 是「长度」而不是目标路径，于是临时文件被 mv 成当前目录下名为 4096 的文件，
#      目标目录永远是空的 → /lib/firmware 下 flash-calibration.bin / bosa-calibration.bin /
#      a2h.bin 全是悬空软链接，WiFi 校准与 BOSA 校准拿不到数据。
#      修法：mkdir -p 目标目录 + mv "$tmp" "$3"。
#   2. 校验 rootfs overlay 里的 WiFi AP 固件齐全（上游没有任何包安装它们，
#      只能由 files/lib/firmware/realtek/tyfza1/ 提供）。

set -euo pipefail

ASSETS="${ASSETS:-$(cd "$(dirname "$0")/.." && pwd)}"
WRT="${WRT:-$ASSETS/wrt}"
FACTORY="$WRT/package/tyfza1-pon-control/files/tyfza1-factory"
FW_DIR="$ASSETS/files/lib/firmware/realtek/tyfza1"

fail() { echo "ERROR: $*" >&2; exit 1; }

# ---------- 1. tyfza1-factory: factory_blob 目标参数 ----------
[ -f "$FACTORY" ] || fail "找不到 $FACTORY（上游目录结构变了？）"

if grep -q 'mv "\$tmp" "\$2"' "$FACTORY"; then
  python3 - "$FACTORY" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
old = '\t\tmv "$tmp" "$2"'
new = '\t\tmkdir -p "${3%/*}"\n\t\tmv "$tmp" "$3"'
if old not in text:
    raise SystemExit('ERROR: 未找到预期的 mv "$tmp" "$2" 行（缩进不符）')
p.write_text(text.replace(old, new, 1), encoding='utf-8', newline='\n')
print('patched tyfza1-factory: factory_blob -> mv "$tmp" "$3"')
PY
else
  echo "tyfza1-factory 已是修好的版本，跳过"
fi

grep -q 'mv "\$tmp" "\$3"' "$FACTORY" \
  || fail 'tyfza1-factory 修补失败：没有 mv "$tmp" "$3"'
! grep -q 'mv "\$tmp" "\$2"' "$FACTORY" \
  || fail 'tyfza1-factory 仍残留 mv "$tmp" "$2"'

# 空块（R10 的 0x4000 bosa / 0x5000 a2h 区域整段 0xFF）会静默跳过，
# 加一条 logger 便于真机排查「校准软链接悬空」这类问题。
if ! grep -q 'is empty, skipped' "$FACTORY"; then
  python3 - "$FACTORY" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
old = '\t\tchmod 0644 "$tmp"\n'
assert old in text, 'chmod line not found'
text = text.replace(old, '', 1)   # 让 chmod 只作用于成功分支后的临时文件
old_else = '\telse\n\t\trm -f "$tmp"\n\t\treturn 1\n'
new_else = '\telse\n\t\tlogger -t tyfza1-factory "$3 is empty, skipped"\n\t\trm -f "$tmp"\n\t\treturn 1\n'
assert old_else in text, 'else branch not found'
text = text.replace(old_else, new_else, 1)
text = text.replace('\t\tmv "$tmp" "$3"\n', '\t\tchmod 0644 "$tmp"\n\t\tmv "$tmp" "$3"\n', 1)
p.write_text(text, encoding='utf-8', newline='\n')
print('patched tyfza1-factory: log skipped blobs')
PY
fi
grep -q 'is empty, skipped' "$FACTORY" \
  || fail 'tyfza1-factory 缺少跳过日志'

# 修好后 factory_blob 必须保留三个位置参数的用法，避免上游再次改动后静默错位
grep -q 'factory_blob \$((0x2000)) 4096' "$FACTORY" \
  || fail 'factory_blob 调用点与预期不符（上游改动？）'

# ---------- 2. WiFi AP 固件齐全性 ----------
# 上游没有任何包提供这些 bin，缺一个驱动就 request_firmware -2 直接失败。
EXPECTED="
rtl8852c-u1-ap.bin 406448
rtl8852c-u2-ap.bin 369160
rtl8192xb-u1-ap.bin 387680
rtl8192xb-u2-ap.bin 387752
array_mp_8852c_nctl_reg.bin 14256
array_mp_8852c_nctl_reg_a.bin 14152
array_mp_8192xb_nctl_reg.bin 11368
"

count=0
while read -r name size; do
  [ -n "${name:-}" ] || continue
  f="$FW_DIR/$name"
  [ -f "$f" ] || fail "缺少 WiFi 固件 $f"
  actual=$(stat -c %s "$f")
  [ "$actual" = "$size" ] \
    || fail "$name 大小不符：期望 $size，实际 $actual（文件被截断？）"
  count=$((count + 1))
done <<EOF
$EXPECTED
EOF

[ "$count" = 7 ] || fail "WiFi 固件数量异常：$count != 7"
extra=$(find "$FW_DIR" -maxdepth 1 -type f -name '*.bin' | wc -l)
[ "$extra" = 7 ] || fail "WiFi 固件目录里有 $extra 个 .bin，期望 7 个（多余文件需确认用途）"

echo "patch-upstream OK: factory_blob 已修，WiFi 固件 7/7 校验通过"
