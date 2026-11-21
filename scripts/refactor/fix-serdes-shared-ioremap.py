#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""
PT1570-H10-CU / refactor: make the serdes PHY driver map lane registers
non-exclusively so 2.5G (serdes) and WiFi (pcie-controls) can coexist.

Root cause (verified on-device 2026-11-21):
  phy-rtl9617c-serdes.c maps six lane registers with
  devm_platform_ioremap_resource_byname(), which calls request_mem_region()
  and claims each region exclusively.  The pcie-controls driver (required by
  both WiFi cards) claims the overlapping phy-control window first, so the
  serdes probe fails with -EBUSY on 0xf43200c4.  A missing 2.5G serdes PHY
  then defers the whole NI controller forever, so user space never starts.
  The only way the board booted before was disabling the pcie nodes, which
  killed WiFi.

Fix:
  Map those six regions with platform_get_resource_byname() + devm_ioremap()
  (no request_mem_region), so both drivers share the lane register window.
  Hardware uses different bits of the same window for different lanes, by
  design (the board DTS documents this).

Idempotent: running twice is a no-op.

Usage:
  python3 fix-serdes-shared-ioremap.py <path-to-phy-rtl9617c-serdes.c>
"""
import pathlib
import re
import sys

MARKER = "static int rtl9617c_serdes_probe(struct platform_device *pdev)"
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
OLD = re.compile(r'devm_platform_ioremap_resource_byname\(pdev,\s*"([^"]+)"\)')


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: fix-serdes-shared-ioremap.py <serdes.c>")
    p = pathlib.Path(sys.argv[1])
    s = p.read_text(encoding="utf-8")

    if "rtl9617c_serdes_ioremap_shared" in s:
        print("  serdes already patched (idempotent)")
        return
    if MARKER not in s:
        raise SystemExit("ERROR: probe marker not found -> wrong file")

    s = s.replace(MARKER, HELPER + MARKER, 1)
    start = s.index(MARKER)
    end = s.index("\n}\n", start) + 3
    body = s[start:end]
    new_body, n = OLD.subn(r'rtl9617c_serdes_ioremap_shared(pdev, "\1")', body)
    if n != 6:
        raise SystemExit("ERROR: expected 6 ioremap sites, found %d" % n)
    p.write_text(s[:start] + new_body + s[end:], encoding="utf-8")
    print("  patched %d ioremap sites in %s" % (n, p))


if __name__ == "__main__":
    main()
