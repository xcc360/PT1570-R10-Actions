#!/bin/bash
# 修补上游源码树里与本机型相关的缺陷（幂等，可重复执行）。
#
# 用法：
#   ASSETS=<资产目录> WRT=<源码树> bash scripts/patch-upstream.sh
#
# 修三件事：
#   1. package/tyfza1-pon-control/files/tyfza1-factory 的 factory_blob() 参数错位：
#      函数签名是 factory_blob <offset> <size> <dest>，但结尾写的是
#        mv "$tmp" "$2"
#      $2 是「长度」而不是目标路径，于是临时文件被 mv 成当前目录下名为 4096 的文件，
#      目标目录永远是空的 → /lib/firmware 下 flash-calibration.bin / bosa-calibration.bin /
#      a2h.bin 全是悬空软链接，WiFi 校准与 BOSA 校准拿不到数据。
#      修法：mkdir -p 目标目录 + mv "$tmp" "$3"。
#   2. 校验 rootfs overlay 里的 WiFi AP 固件齐全（上游没有任何包安装它们，
#      只能由 files/lib/firmware/realtek/tyfza1/ 提供）。
#   3. 放开 generic/510 fitblk 的 4 MiB FIT 上限（改 16384 页 + kvmalloc），
#      否则 /dev/fitblk0 建不出来，刷入态启动直接灯全灭。

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

# ---------- 3. fitblk：解除 4MiB FIT 上限（刷入态起不来的根因） ----------
#
# target/linux/generic/pending-6.18/510-block-add-uImage.FIT-subimage-block-driver.patch
# 里写着：
#   #define FIT_MAX_PAGES 1024
#   if (size > PAGE_SIZE * FIT_MAX_PAGES) ret = -EOPNOTSUPP;
#   fit = kmalloc(size, GFP_KERNEL);
# 4 KiB 页时上限只有 4 MiB，而本机型 sysupgrade 的 FIT 是 20.7 MB、initramfs 是
# 23.6 MB，于是 probe 直接返回 -95：
#   fitblk fitblk: probe with driver fitblk failed with error -95
# /dev/fitblk0 永远不出现 → 内核按 root=/dev/fitblk0 挂根失败 → 灯全灭。
# initramfs 不需要 root 设备，所以内存启动一直正常：这正是"内存能起、刷入起不来"
# 的唯一原因。
#
# 修法：上限提到 16384 页（64 MiB），并把整块 kmalloc 改成 kvmalloc —— 20 MB
# 的 kmalloc 会因伙伴系统 MAX_ORDER 直接 -ENOMEM，vmalloc 走 vmap 区才拿得到。
FITBLK_PATCH="$WRT/target/linux/generic/pending-6.18/510-block-add-uImage.FIT-subimage-block-driver.patch"
[ -f "$FITBLK_PATCH" ] || fail "找不到 $FITBLK_PATCH（上游 pending 目录结构变了？）"

python3 - "$FITBLK_PATCH" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
subs = [
    ('#define FIT_MAX_PAGES 1024', '#define FIT_MAX_PAGES 16384'),
    ('fit = kmalloc(size, GFP_KERNEL);', 'fit = kvmalloc(size, GFP_KERNEL);'),
    ('kfree(fit);', 'kvfree(fit);'),
]
for old, new in subs:
    if text.count(old) != 1:
        raise SystemExit('ERROR: fitblk 补丁里 %r 出现 %d 次（期望 1 次，上游改动？）'
                         % (old, text.count(old)))
    text = text.replace(old, new, 1)
p.write_text(text, encoding='utf-8', newline='\n')
print('patched fitblk: FIT_MAX_PAGES 1024 -> 16384, kmalloc -> kvmalloc')
PY

grep -q '#define FIT_MAX_PAGES 16384' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁未被修改（FIT_MAX_PAGES）'
grep -q 'fit = kvmalloc(size, GFP_KERNEL);' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁未被修改（kvmalloc）'
grep -q 'kvfree(fit);' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁未被修改（kvfree）'
! grep -q 'fit = kmalloc(size, GFP_KERNEL);' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁仍残留 kmalloc(size)'
echo "FITBLK_LIMIT_OK=True (16384 pages = 64 MiB, kvmalloc)"

echo "patch-upstream OK: factory_blob 已修，WiFi 固件 7/7 校验通过，fitblk 上限已放开"
