#!/usr/bin/env python3
"""校验「统一 UBI 方案」镜像能否在新 U-Boot 的 rtk_boot 路径下自洽启动。

背景（2026-11-13 二次修订，结论与上一版相反）：
  * 用户已确认 U-Boot env 做过清空、恢复编译默认（pt1570.env 无 bootargs），
    所以 fdt_chosen() 里 board_fdt_chosen_bootargs() 返回 NULL，`if (str)`
    不成立，DTB 的 /chosen/bootargs 不会被覆盖。"NAND env 残留污染"不是根因。
  * 用户已确认 Run14 刷机验证能启动（当时只是 IPv4 网络层不通，IPv6 可访问，
    已由 95-pt1570-wan-default 单独修复）。说明刷入态启动本来是通的。
  * 逐个解包 fw12~fw22 的内嵌 DTB 做差分：
      fw12/fw14（能启动）  : bootargs 无 root= / 无 u-boot,version
      fw15..fw22（起不来）: 多了 "root=/dev/fitblk0 rootwait rootfstype=squashfs"
                            和 u-boot,version="2025.01"
      FIT 结构、rootdisk phandle、内核配置两边完全一致。
    回归点 = run15 起往 DTS 里加的 /chosen 覆盖块。
  * 挂根本来由内核侧完成：CONFIG_MTD_ROOTFS_ROOT_DEV 为 chosen.rootdisk
    指向的卷建 ubiblock；510-* 的 fitblk 驱动在 device_add_disk() 之后
    `if (!ROOT_DEV) ROOT_DEV = disk->part0->bd_dev;` 自设根设备（/dev/fit0）。
    fdt_chosen() 无条件写 u-boot,version，fitblk_init() 门闩天然满足。
    因此 bootargs 里不该出现 root= / rootwait / ubi.mtd / ubi.block。

检查项：
  1. FIT 结构：kernel / fdt / rootfs 子镜像齐全，default config 的
     loadables 里包含 rootfs 子镜像名；
  2. rootfs 子镜像 type=filesystem，data-position 与 data-size 都 4K 对齐
     （内核 fitblk 驱动会跳过未对齐的子镜像）；
  3. DTB 的 /chosen/bootargs 不得含 root= / rootwait / rootfstype /
     ubi.mtd= / ubi.block= —— 出现任何一个都是 run15 回归复发；
  4. DTB 的 /chosen/rootdisk phandle 必须指向 volname="fit" 的 UBI 卷节点；
  5. DTB 必须带 `compatible = "linux,ubi"` 的分区节点（内核自动 attach）；
  6. model 不得再出现 "ABI"（应为 "RTL9617C UBI"，与状态页一致）。

用法：
  python3 verify-fit-boot.py <xxx-sysupgrade.itb>
  python3 verify-fit-boot.py --dtb <xxx.dtb>        # 只做 DTB 部分
"""
import struct
import sys

FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9

# run15 回归特征：这些参数本该由内核/驱动自己处理，写进 bootargs 反而挂不上根。
FORBIDDEN_BOOTARGS = ("root=", "rootwait", "rootfstype=", "ubi.mtd=", "ubi.block=")


def be32(b, o):
    return struct.unpack_from(">I", b, o)[0]


class Node:
    __slots__ = ("name", "props", "children", "parent")

    def __init__(self, name, parent=None):
        self.name = name
        self.props = {}
        self.children = []
        self.parent = parent

    def path(self):
        p, n = [], self
        while n is not None and n.name != "/":
            p.append(n.name)
            n = n.parent
        return "/" + "/".join(reversed(p))

    def walk(self):
        yield self
        for c in self.children:
            yield from c.walk()

    def find(self, path):
        cur = self
        for part in [x for x in path.split("/") if x]:
            for c in cur.children:
                if c.name == part or c.name.split("@")[0] == part:
                    cur = c
                    break
            else:
                return None
        return cur


def parse_fdt(blob, base=0):
    if be32(blob, base) != 0xD00DFEED:
        raise ValueError("不是 FDT（magic=%08x）" % be32(blob, base))
    off_struct = be32(blob, base + 8)
    off_strings = be32(blob, base + 12)
    o = base + off_struct
    root = Node("/")
    cur = root
    while True:
        tok = be32(blob, o)
        o += 4
        if tok == FDT_BEGIN_NODE:
            end = blob.index(b"\0", o)
            name = blob[o:end].decode("utf-8", "replace")
            o = (end + 4) & ~3
            if name:
                node = Node(name, cur)
                cur.children.append(node)
                cur = node
        elif tok == FDT_END_NODE:
            if cur.parent is not None:
                cur = cur.parent
        elif tok == FDT_PROP:
            ln = be32(blob, o)
            nameoff = be32(blob, o + 4)
            o += 8
            val = blob[o:o + ln]
            o = (o + ln + 3) & ~3
            s = blob[base + off_strings + nameoff:]
            pname = s[:s.index(b"\0")].decode()
            cur.props[pname] = val
        elif tok == FDT_NOP:
            continue
        elif tok == FDT_END:
            break
        else:
            raise ValueError("非法 token %d @ %d" % (tok, o))
    return root


def sval(raw):
    return raw.rstrip(b"\0").decode("utf-8", "replace")


def fail(msg):
    print("::error::FIT_BOOT: " + msg)
    sys.exit(1)


ALLOW_LEGACY_MODEL = False


def check_devtree(dtb, label="DTB"):
    """校验 /chosen 是否满足 fitblk 自洽启动条件。返回 True/抛 fail。"""
    dev = parse_fdt(dtb)

    model = sval(dev.props.get("model", b""))
    print("  model: %s" % (model or "<空>"))
    if "ABI" in model:
        if ALLOW_LEGACY_MODEL:
            print("  ::warning:: model 仍是 ABI（--allow-legacy-model 已放行，仅用于差分验证历史固件）")
        else:
            fail("%s 的 model 仍是 %r —— 应为 '... (RTL9617C UBI)'，不是 ABI"
                 % (label, model))

    chosen = dev.find("/chosen")
    if chosen is None:
        fail("%s 没有 /chosen 节点" % label)

    bootargs = sval(chosen.props.get("bootargs", b""))
    print("  bootargs: %s" % (bootargs or "<空>"))
    for bad in FORBIDDEN_BOOTARGS:
        if bad in bootargs:
            fail("%s 的 bootargs 含 %r —— 这是 run15 回归（fw12/fw14 能启动时"
                 "没有这些参数）。挂根由 CONFIG_MTD_ROOTFS_ROOT_DEV + fitblk 驱动"
                 "自设 ROOT_DEV 完成，显式 root= 反而把内核钉在 /dev/fitblk0 这个"
                 "驱动并不创建的节点名上，rootwait 无限等 → 灯全灭"
                 % (label, bad))
    print("  bootargs 干净（无 root=/rootwait/ubi.*）: OK")

    # 内核自动 attach UBI 的前提：分区节点带 compatible = "linux,ubi"
    ubi_nodes = [n for n in dev.walk()
                 if b"linux,ubi" in n.props.get("compatible", b"")]
    if not ubi_nodes:
        fail("%s 找不到 `compatible = \"linux,ubi\"` 的分区节点 —— "
             "内核不会自动 attach UBI，rootdisk 指向的卷无块设备" % label)
    print("  linux,ubi 分区: %s" % ubi_nodes[0].path())

    rd = chosen.props.get("rootdisk")
    if rd is None:
        fail("%s 的 /chosen 缺少 rootdisk phandle" % label)
    phandle = be32(rd, 0)
    target = None
    for n in dev.walk():
        p = n.props.get("phandle") or n.props.get("linux,phandle")
        if p is not None and be32(p, 0) == phandle:
            target = n
            break
    if target is None:
        fail("%s 的 rootdisk phandle %d 找不到对应节点" % (label, phandle))
    volname = sval(target.props.get("volname", b""))
    print("  rootdisk -> %s (volname=%r)" % (target.path(), volname))
    if volname != "fit":
        fail("%s 的 rootdisk 指向 volname=%r，不是 fit 卷" % (label, volname))
    return True


def main():
    global ALLOW_LEGACY_MODEL
    if len(sys.argv) < 2:
        fail("用法: verify-fit-boot.py [--dtb] [--allow-legacy-model] <image.itb|dtb>")
    args = sys.argv[1:]
    dtb_only = False
    while args and args[0].startswith("--"):
        if args[0] == "--dtb":
            dtb_only = True
        elif args[0] == "--allow-legacy-model":
            # 只用于拿历史固件（fw12/fw14）做启动形态差分，正式产物不得使用
            ALLOW_LEGACY_MODEL = True
        else:
            fail("未知选项 %s" % args[0])
        args = args[1:]
    if not args:
        fail("缺少文件名")
    path = args[0]
    blob = open(path, "rb").read()
    print("file: %s (%d bytes)" % (path, len(blob)))

    if dtb_only or path.endswith(".dtb"):
        check_devtree(blob, label=path)
        print("FIT_BOOT_OK=True")
        return

    fit = parse_fdt(blob)
    print("FIT description: %s" % sval(fit.props.get("description", b"")))

    images = fit.find("/images")
    if images is None:
        fail("FIT 缺少 /images")

    subs = {}
    for img in images.children:
        t = sval(img.props.get("type", b""))
        subs[img.name] = {
            "type": t,
            "pos": be32(img.props["data-position"], 0) if "data-position" in img.props else None,
            "size": be32(img.props["data-size"], 0) if "data-size" in img.props else None,
        }
        print("  %-12s type=%-12s pos=%-10s size=%s" % (
            img.name, t, subs[img.name]["pos"], subs[img.name]["size"]))

    cfgs = fit.find("/configurations")
    if cfgs is None:
        fail("FIT 缺少 /configurations")
    default = sval(cfgs.props.get("default", b"")) or "config-1"
    cfg = cfgs.find(default)
    if cfg is None:
        fail("找不到默认配置 %s" % default)

    loadables = [x for x in sval(cfg.props.get("loadables", b"")).split("\0") if x]
    kernel = sval(cfg.props.get("kernel", b""))
    fdt_name = sval(cfg.props.get("fdt", b""))
    print("  config %s: kernel=%s fdt=%s loadables=%s" % (default, kernel, fdt_name, loadables))

    if not fdt_name or fdt_name not in subs:
        fail("config 里没有有效的 fdt 子镜像")
    if not kernel or kernel not in subs:
        fail("config 里没有有效的 kernel 子镜像")

    rootfs = [n for n in loadables if n in subs and subs[n]["type"] == "filesystem"]
    if not rootfs:
        fail("loadables 里没有 type=filesystem 的 rootfs 子镜像（fitblk 不会创建 /dev/fitblk0）")
    rf = subs[rootfs[0]]
    print("  rootfs 子镜像: %s pos=%s size=%s" % (rootfs[0], rf["pos"], rf["size"]))
    if rf["pos"] is None or rf["size"] is None:
        fail("rootfs 子镜像缺少 data-position / data-size")
    if rf["pos"] % 4096 or rf["size"] % 4096:
        fail("rootfs 子镜像未按 4K 对齐（pos=%d size=%d），fitblk 会直接跳过"
             % (rf["pos"], rf["size"]))
    if rf["pos"] + rf["size"] > len(blob):
        fail("rootfs 子镜像超出文件范围（%d > %d）" % (rf["pos"] + rf["size"], len(blob)))

    fdt_img = subs[fdt_name]
    if fdt_img["pos"] is None or fdt_img["size"] is None:
        fail("fdt 子镜像缺少 data-position / data-size")
    dtb = blob[fdt_img["pos"]:fdt_img["pos"] + fdt_img["size"]]
    check_devtree(dtb, label="DTB(%s)" % fdt_name)
    print("FIT_BOOT_OK=True")


if __name__ == "__main__":
    main()
