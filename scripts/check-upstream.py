#!/usr/bin/env python3
"""比较 PT15xx workflow 固定 ref 与上游 HEAD。

用法（仓库根目录）：
    python3 scripts/check-upstream.py

返回 0 表示三板 OpenWrt ref 与 U-Boot ref 都跟上上游；返回 1 表示有差距。
公开 API 有频率限制（未认证 60 次/小时），本脚本每次只请求 2 次。
"""
import json
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
OPENWRT_REPO = "lyq1996/rtl9617c-openwrt"
OPENWRT_BRANCH = "refactor"
UBOOT_REPO = "lyq1996/rtl9617c-uboot"
UBOOT_BRANCH = "main"


def branch_head(repo, branch):
    url = f"https://api.github.com/repos/{repo}/branches/{branch}"
    req = urllib.request.Request(url, headers={"User-Agent": "pt15xx-upstream-check"})
    with urllib.request.urlopen(req, timeout=20) as r:
        data = json.load(r)
    return data["commit"]["sha"]


def local_refs():
    wf = (ROOT / ".github/workflows/build-ont-unified.yml").read_text(encoding="utf-8")
    h10 = re.search(r"inputs\.source_ref \|\| '([0-9a-f]{40})'", wf)
    defaults = re.findall(r"DEFAULT_REF='([0-9a-f]{40})'", wf)
    ub = (ROOT / ".github/workflows/build-uboot-youhua.yml").read_text(encoding="utf-8")
    uboot = re.search(r"inputs\.uboot_ref \|\| '([0-9a-f]{40})'", ub)
    if not h10 or not uboot or not defaults:
        raise SystemExit("ERROR: 未能从 workflow 解析出固定 ref")
    return h10.group(1), defaults, uboot.group(1)


def main():
    openwrt_head = branch_head(OPENWRT_REPO, OPENWRT_BRANCH)
    uboot_head = branch_head(UBOOT_REPO, UBOOT_BRANCH)
    h10, defaults, uboot_ref = local_refs()

    print(f"OpenWrt upstream {OPENWRT_REPO}@{OPENWRT_BRANCH}: {openwrt_head}")
    print(f"  H10   default ref: {h10}")
    for i, ref in enumerate(defaults, 1):
        print(f"  ref#{i} default ref: {ref}")
    print(f"U-Boot upstream {UBOOT_REPO}@{UBOOT_BRANCH}: {uboot_head}")
    print(f"  U-Boot default ref: {uboot_ref}")

    ok = True
    expected = [h10] + defaults
    if any(ref != openwrt_head for ref in expected) or len(expected) != 3:
        print("BEHIND: 三板 OpenWrt 固定 ref 未全部跟上上游 HEAD；按 docs/UPSTREAM-SYNC-POLICY.md 验证后更新。")
        ok = False
    else:
        print("OK: 三板 OpenWrt 固定 ref 全部等于上游 HEAD。")
    if uboot_ref != uboot_head:
        print("BEHIND: U-Boot 固定 ref 落后上游 HEAD；确认后更新 build-uboot-youhua.yml。")
        ok = False
    else:
        print("OK: U-Boot 固定 ref 等于上游 HEAD。")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
