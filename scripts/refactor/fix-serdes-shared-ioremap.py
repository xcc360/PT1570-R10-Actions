#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""
PT1570-H10-CU: make the serdes PHY driver map lane registers non-exclusively
so 2.5G (serdes) and WiFi (OOT pcie-controls) can coexist on the shared
lane-register window.

Root cause (verified on-device 2026-11-21):
  The serdes driver maps shared lane registers with
  devm_platform_ioremap_resource_byname(), which calls request_mem_region()
  and claims each region exclusively.  Our OOT pcie-controls driver (required
  by both WiFi cards) claims the overlapping windows first, so serdes probe
  fails with -EBUSY and the whole NI controller defers forever.

Two upstream layouts are supported (idempotent for both):

  * pre-Taurus refactor (phy-rtl9617c-serdes.c):
      6 x devm_platform_ioremap_resource_byname() in rtl9617c_serdes_probe();
      we inject rtl9617c_serdes_ioremap_shared() helper and swap all 6.

  * Taurus (phy-taurus-serdes.c, 2026-11-21+):
      taurus_serdes_probe() already uses a non-exclusive helper
      taurus_serdes_map() for lane-ctrl / lane-reset / lane-power, but
      lane-analog (0xf433b000) and lane-tx (0xf4600000) still use the
      exclusive byname variant.  Those two overlap pcie-controls' sgmii-analog
      / sgmii-serdes windows, so we swap just those two calls to the existing
      helper (sds at 0xf550d000 is not shared, leave it alone).

Usage:
  python3 fix-serdes-shared-ioremap.py <path-to-serdes.c>
"""
import pathlib
import sys

MARKER_OLD = "static int rtl9617c_serdes_probe(struct platform_device *pdev)"
MARKER_NEW = "static int taurus_serdes_probe(struct platform_device *pdev)"
OLD_HELPER_NAME = "rtl9617c_serdes_ioremap_shared"

HELPER = """/*
 * Lane control registers (lane-ctrl/reset/power/analog/tx) are shared with
 * the pcie-controls driver: both operate on the same lane-register window,
 * using different bits for different lanes. devm_platform_ioremap_resource_byname()
 * calls request_mem_region() which is exclusive, so the second prober gets
 * -EBUSY. Map without claiming the region so both drivers can coexist.
 */
static void __iomem *rtl9617c_serdes_ioremap_shared(struct platform_device *pdev,
                                                    const char *name)
{
        struct resource *res = platform_get_resource_byname(pdev, IORESOURCE_MEM, name);

        if (!res)
                return ERR_PTR(-ENODEV);
        return devm_ioremap(&pdev->dev, res->start, resource_size(res));
}

"""


def func_body(src, marker):
    start = src.index(marker)
    end = src.index("\n}\n", start) + 3
    return start, end, src[start:end]


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: fix-serdes-shared-ioremap.py <serdes.c>")
    p = pathlib.Path(sys.argv[1])
    s = p.read_text(encoding="utf-8")

    # --- pre-Taurus refactor layout ---
    if MARKER_OLD in s:
        if OLD_HELPER_NAME in s:
            print("  serdes already patched (idempotent, pre-Taurus)")
            return
        import re
        s = s.replace(MARKER_OLD, HELPER + MARKER_OLD, 1)
        start, end, body = func_body(s, MARKER_OLD)
        new_body, n = re.subn(
            r'devm_platform_ioremap_resource_byname\(pdev,\s*"([^"]+)"\)',
            r'rtl9617c_serdes_ioremap_shared(pdev, "\1")', body)
        if n != 6:
            raise SystemExit("ERROR: expected 6 ioremap sites, found %d" % n)
        p.write_text(s[:start] + new_body + s[end:], encoding="utf-8")
        print("  patched %d ioremap sites in %s (pre-Taurus)" % (n, p))
        return

    # --- Taurus layout ---
    if MARKER_NEW in s:
        if ('taurus_serdes_map(pdev, "lane-analog")' in s and
                'taurus_serdes_map(pdev, "lane-tx")' in s):
            print("  serdes already patched (idempotent, Taurus)")
            return
        start, end, body = func_body(s, MARKER_NEW)
        new_body = body
        cnt = 0
        for reg in ("lane-analog", "lane-tx"):
            old = 'devm_platform_ioremap_resource_byname(pdev, "%s")' % reg
            new = 'taurus_serdes_map(pdev, "%s")' % reg
            if old in new_body:
                new_body = new_body.replace(old, new)
                cnt += 1
        if cnt != 2:
            raise SystemExit("ERROR: expected 2 exclusive lane windows in Taurus probe, found %d" % cnt)
        p.write_text(s[:start] + new_body + s[end:], encoding="utf-8")
        print("  patched %d shared lane windows in %s (Taurus)" % (cnt, p))
        return

    raise SystemExit("ERROR: neither rtl9617c_serdes_probe nor taurus_serdes_probe found -> wrong file")


if __name__ == "__main__":
    main()
