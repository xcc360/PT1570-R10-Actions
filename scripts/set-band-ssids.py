#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 /etc/config/wireless 的 SSID 改成「型号 + 频段」，彻底禁用双频合一。

两台设备（PT1570-R10 / PT1570-H10-CU）出厂配置的 radio0=5G、radio1=2.4G
目前共用一个 SSID（型号串），即「双频合一」。本脚本按每个 wifi-device 的
option band 自动判定频段，把对应 wifi-iface 的 ssid 改成：

    <MODEL>-5G      （band 5g，radio0）
    <MODEL>-2.4G    （band 2g，radio1）

用法：
    python3 set-band-ssids.py <wireless-file> <MODEL>

    # R10
    python3 scripts/set-band-ssids.py files/etc/config/wireless PT1570-R10
    # H10-CU
    python3 scripts/set-band-ssids.py cu-h10/fw/files-cu/etc/config/wireless PT1570-H10-CU

设计要点（保证幂等 + 防呆）：
  * 从 wifi-device 的 option band 反查频段，不写死 radio0/radio1 的顺序，
    换 phy 枚举顺序也不会把 5G/2.4G 标签贴反；
  * band 只认 2g / 5g / 6g，未知值直接报错，避免贴上错误标签；
  * 改完断言：SSID 数 == wifi-iface 数，且两两不同（杜绝再次双频合一）；
  * 纯文本替换，只动 option ssid 行，保留注释、option 顺序、其它选项原样。
"""
import re
import sys
from pathlib import Path

BAND_LABEL = {"2g": "2.4G", "5g": "5G", "6g": "6G"}


def die(msg):
    print(f"set-band-ssids: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 3:
        die("usage: set-band-ssids.py <wireless-file> <MODEL>")
    path = Path(sys.argv[1])
    model = sys.argv[2].strip()
    if not model:
        die("MODEL 不能为空")
    if not path.is_file():
        die(f"找不到无线配置文件 {path}")

    # newline='' 关闭 universal-newline 转换：read 保留原始 \r\n，write 不做
    # 平台相关的 \n -> os.linesep 翻译（在 Windows 本机跑也不会把 LF 写成 CRLF）。
    with path.open("r", encoding="utf-8", newline="") as fh:
        lines = fh.read().splitlines(keepends=True)

    # 1) 收集每个 wifi-device 的频段：radio 名 -> band
    radio_band = {}
    cur_radio = None
    for ln in lines:
        m = re.match(r"\s*config\s+wifi-device\s+'([^']+)'", ln)
        if m:
            cur_radio = m.group(1)
            continue
        if re.match(r"\s*config\s+", ln):
            cur_radio = None
            continue
        if cur_radio:
            m = re.match(r"\s*option\s+band\s+'([^']+)'", ln)
            if m:
                radio_band[cur_radio] = m.group(1).strip()
    if not radio_band:
        die("未从任何 wifi-device 读到 option band")

    # 2) 逐 wifi-iface：按 option device 反查频段，改写 option ssid
    out = []
    cur_iface = None
    cur_device = None
    ssids = []
    iface_count = 0
    for ln in lines:
        m = re.match(r"\s*config\s+wifi-iface\s+'([^']+)'", ln)
        if m:
            cur_iface = m.group(1)
            cur_device = None
            iface_count += 1
            out.append(ln)
            continue
        if re.match(r"\s*config\s+", ln):
            cur_iface = None
            cur_device = None
            out.append(ln)
            continue
        if cur_iface:
            m = re.match(r"\s*option\s+device\s+'([^']+)'", ln)
            if m:
                cur_device = m.group(1).strip()
                out.append(ln)
                continue
            m = re.match(r"(\s*)option\s+ssid\s+'[^']*'(\s*)$", ln.rstrip("\r\n"))
            if m:
                if not cur_device:
                    die(f"wifi-iface {cur_iface} 的 ssid 之前没有 option device")
                band = radio_band.get(cur_device)
                if not band:
                    die(f"wifi-iface {cur_iface} 的 device {cur_device} 没有对应 band")
                label = BAND_LABEL.get(band)
                if not label:
                    die(f"device {cur_device} 的 band='{band}' 不是 2g/5g/6g，拒绝贴标签")
                newline = "\r\n" if ln.endswith("\r\n") else "\n"
                out.append(f"{m.group(1)}option ssid '{model}-{label}'{m.group(2)}{newline}")
                ssids.append(f"{model}-{label}")
                continue
        out.append(ln)

    if iface_count == 0:
        die("没有找到任何 wifi-iface")
    if len(ssids) != iface_count:
        die(f"wifi-iface 数={iface_count} 但改写的 ssid 数={len(ssids)}，配置结构异常")
    if len(ssids) != len(set(ssids)):
        die(f"改写后 SSID 仍有重复（双频合一未消除）: {ssids}")

    with path.open("w", encoding="utf-8", newline="") as fh:
        fh.write("".join(out))
    print(f"set-band-ssids: OK  {path}")
    print(f"  SSIDs: {', '.join(ssids)}  (dual-band unified: NO)")


if __name__ == "__main__":
    main()
