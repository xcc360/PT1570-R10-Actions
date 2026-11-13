# PT1570 → 统一 UBI 方案 迁移检查清单（执行前必读）

> **本文件是方案与检查表，不是已执行的操作。** 迁移会擦掉 `ubi_device` 整片，
> 等于全量重刷；本轮未连接设备、未刷机、未编译。
>
> 🔄 **2026-11-09 晚范围与结论变更**：按用户决定收窄为 **R10-only**（H10 暂缓）。
> 设备 U-Boot 已定案为 `lyq1996/rtl9617c-uboot@refactor 2026.07-g9abafc0572b2`，
> 源码确认 `rtk_boot` 就是 统一 UBI 引导（读 `fit` → 自动建 `rootfs_data` → `bootm`），
> **不需要重刷 U-Boot**；旧阻断项 C 已解除、A 降级、B 可从路径中移除。
> 详见 `PT1570-R10-单机型验证报告-20261109.md`。

## 0. 目标状态

| 项 | 迁移后 |
| --- | --- |
| U-Boot | **保持现状**（`refactor@9abafc0572b2`），内置 `bootcmd=bootmenu` → `rtk_boot` / `rtk_recovery` |
| env | 清掉旧的手写 `ubi read ... lzmadec ... bootcmd`，由 U-Boot 内置默认重建 |
| UBI 卷 | `factory`（8 MiB static，RTLFACT1）+ `fit`（FIT 固件，吃满剩余）+ `rootfs_data`（首次启动自动建，autoresize） |
| 固件 | `sysupgrade.itb`（FIT `external-static-with-rootfs`，`fitblk` 挂 rootfs） |
| sysupgrade | `CI_KERNPART=fit` / `CI_UBIPART=ubi_device` / `nand_do_upgrade` |
| 不再存在 | `ubi_k1` / `ubi_r1` / `ubi_DTB1` / `ubi_Config` / `ubi_apps` / 原厂 A/B 槽、`/overlay -> /rom/overlay` 符号链接 hack、32.09 MiB rootfs 上限 |

## 1. 阻断项（未解决就不要动手）

> **状态速览（2026-11-09 晚）**：
> ① 指纹不匹配 → **可绕过**（不需重刷 U-Boot）；② R10 factory → ✅ 已校验；
> ③ U-Boot 板型 → **降级**：两板型 boot layout 相同，仅 Web Failsafe 网口仍需实测；
> ④ DTS → **R10 静态移植完成、仍带 UNVERIFIED**；⑤ env → **清 env 即切 FIT**；
> ⑥ `rtk_boot` 实现 → ✅ **已解除**（源码定案）；⑦ H10 → **移出本轮范围**。
> 下面 1–7 保留当时原始记录，执行以本摘要与 R10 单机型验证报告为准。

1. **迁移工具没有这两个机型的 board conf，且 R10 当前指纹已被改掉**（2026-11-09 真机实测）。
   `lyq1996/rtl9617c-migration-tools` 只带 `boards/pt1500.conf` 与 `boards/tyfza1.conf`，
   靠本机 `mtd0` 的 FIP BL2/BL31 payload SHA-256 识别机型，逐字节一致才允许刷入。
   R10 实测 mtd0（两副本 @0x40000 / 0x100000 完全相同）：
   BL2 `ef55fb47e7b0b2a4c6…`、BL31 `94d2b5fb6e81a002…`、BL33 `f5f22eadc2e5d3d3…`，
   与 `tyfza1.conf` 的 `b04b7aba…` / `1f6444e2…` **全不匹配**——因为这台早就刷过 U-Boot，
   原厂 FIP 已被替换，不能再用指纹反推原厂板型。
   → 若要用工具再刷 U-Boot，须新增 conf 填入**当前** BL2/BL31；否则走串口 XModem 路径。
2. **factory 工具没有 pt1570-h10 profile**。`rtl9617c-factory` 只支持 `model=1 tyfza1` 与
   `model=2 pt1500-h10`。本机已有一份 R10 的 `factory-pt1570-r10.bin`（8,388,608 B，
   magic `RTLFACT1`，version 1，image_size 0x800000，**model=4**）——说明它来自另一套生成流程。
   → 统一 UBI 方案的 Web Failsafe 只是把 8 MiB 原样写进 static 卷，OpenWrt 侧按 `nvmem-layout`
   固定偏移读取，**不校验 model**，所以 R10 这份可以继续用。
   ✅ 2026-11-09 已复核：设备上 `factory` 卷（ID 8, static, 8,388,608 B，头部 `RTLFACT1` v1 /
   image_size 0x800000 / model=4）完整读出，SHA-256 `f97d93dbe82e4455…` 与本地
   `factory-pt1570-r10.bin` **逐字节一致**，另存 `pt1570-ci-research/r10-factory-20261109.bin`。此项不再是风险。
   → H10 必须单独生成自己的 factory（MAC / PON SN / 校准数据），**绝不能复制 R10 的**。
3. ⚠️ **降级保留：R10 当前刷的 U-Boot 是 `PT1500-H10-2P5G` 板型构建**（2026-11-09 实测）。
   ✅ 补充：`refactor@9abafc0572b2` 里 `board/yhup/pt1500_h10/layout.c` 与
   `board/tianyi/tyfza1/layout.c` 的 boot layout **完全相同**（fit / rootfs_data / factory），
   且 `board/tianyi/tyfza1/board.c` 注释「Both variants use the internal GPHYs」——
   因此 **不需要换 U-Boot**。剩余风险只剩 Web Failsafe 网页在 4×GE 板上的可达性。
   以下为当时原始描述：
   BL33 段（熵 8.00，已压缩）内唯一板名字符串就是 `PT1500-H10-2P5G`；这与历史记录
   「当初刷的是 qwe-qaq PT1500 U-Boot」吻合。而 R10 实测是 **4×GE（PHY 001ccac4）+ XGPON +
   双 PCIe WiFi**，没有 2.5G switch。当前它只负责读卷跳内核，所以旧方案 能跑；
   但 **`ubi-rebuild` 全程依赖 Web Failsafe 网页，其网口驱动是否适配 R10 未经验证**。
   1570 分支候选板型：`pt1570-h10` / `pt1500-h10-2p5g` / `tyfza1-2p5g` / `tyfza1-4ge`。
   → 动手前必须：确认串口可用；确认/换用与 R10 匹配且 Web Failsafe 网口已验证的 U-Boot；
   或由用户回忆当时刷入的 `boot.bin` 文件名。网口不通又无串口 = 变砖不可恢复。
4. **DTS 未验证**。本资产里的两个 `.dts` 都带 `UNVERIFIED`，只能用来验证编译链路。
   见方案文档第 6 节的真机核对清单。
5. **旧 env 与新版 U-Boot 不一致**：R10 实测 `bootcmd` 仍是手写
   `ubi part ubi_device && ubi read 0x10000000 ubi_k1 && lzmadec … && booti …`，卷表里没有 `fit` 卷；
   但同一份 env 里**已经有** `bootmenu_0=Start OpenWrt=rtk_boot` /
   `bootmenu_1=Start Web Recovery=rtk_recovery`。`/etc/fw_env.config` 配了 mtd1+mtd2 两份，
   且两份内容不同（清 env 必须两片一起擦）。
   清空 env 后新 U-Boot 会自动写回内置默认（已核实 `rtk_board_env_init()` 的行为），
   但**必须先确保 Web Failsafe 可用且 factory/fit 已就位**，否则重启就是黑砖。
6. ✅ **已解除（2026-11-09 晚）**：`u-boot,version = 2026.07-g9abafc0572b2` 反查到
   `lyq1996/rtl9617c-uboot@refactor` HEAD，读 `board/realtek/common/boot.c` 的
   `rtk_boot_system()` 确认就是「`ubi_part` → 读 `fit` 整卷 → `fit_check_format` →
   自动建 `rootfs_data` → `bootm`」。内置 env `bootcmd=bootmenu` + `bootmenu_0=rtk_boot`。
   → **清 env（mtd1+mtd2）即自动切换到 统一 UBI 方案，不需重刷 U-Boot。**
7. **H10 暂缓（DORMANT，移出本轮范围）**：设备未上线，网口版本 / factory / env 均未采集。
   恢复条件见 `PT1570-R10-单机型验证报告-20261109.md` 第 1 节；
   当前 workflow 与注入脚本默认拒绝产出 H10 固件。

## 2. 前置备份（缺一不可）

在旧系统还能启动时：

- [ ] `sh migration/device-preflight.sh > pt1570-preflight.txt`，保存完整输出（含 `fw_printenv` 全量）。
- [ ] 全片物理备份：实测**只有 5 个 mtd**（原写「mtd0–mtd15」为误记）——
      `mtd0` boot 2 MiB、`mtd1` env 256 KiB、`mtd2` env2 256 KiB、`mtd3` static_conf 256 KiB、
      `mtd4` ubi_device 0x0f5c0000 (245.5 MiB)。R10 已有 `D:\ONT\PT1570-R10\BackUp\`。
      ✅ 本轮已落盘 `mtd0`（`pt1570-ci-research/r10-mtd0-20261109.bin`，sha256 `ecbf2deb…`）；
      其余 4 片迁移前仍需各存一份。
- [x] 8 MiB factory bin 及 sha256（R10：`f97d93dbe82e4455…`，已从设备卷重新读出并比对一致）。
- [ ] 本机 PON SN / LOID / MAC、WiFi 校准、原厂 XML 与 `pon_factory` 快照
      （设备上有 `/etc/tyfza1-factory/config.xml` 156,248 B、`config_hs.xml` 37,377 B、
      `pon_factory` 385 B、`/tmp/tyfza1-factory/lan_mac` 18 B）。
- [x] overlay 上的本地修复清单（2026-11-09 实测完整版，见核对报告第 7 节）：
      `/overlay/upper/usr/bin/wifi-guard.sh`（crontab 每分钟 + 已列 `/etc/sysupgrade.conf`）、
      `/etc/config/wireless.bak-wifi-fix`、`radio0 ch36 HE80` / `radio1 disabled ch6`、
      `/etc/uhttpd.crt` + `.key`、`/etc/nftables.d/10-custom-filter-chains.nft`、
      tailscale `--cleanup` 调整、`/overlay -> /rom/overlay` symlink、bootargs `loglevel=4`。
      **新 squashfs 不含这些**，要么通过 `files/` 注入，要么刷完重新应用；注入 nft 片段前先 `fw4 check`。
- [ ] 确认串口可用（115200 8n1），以及 XModem 恢复 FIP 的操作路径（U-Boot README 有）。

## 3. 执行顺序（R10-only，2026-11-09 晚修订）

0. **【新增前置，不写 flash】验证 Web Failsafe 网页可达**：确认串口可用 →
   在旧系统仍正常时进入 `rtk_recovery`，PC 连 `192.168.0.1` 确认网页能打开。
   env 里有 `active_port` / `auto_scan_active_port=1`，但设备用的是 PT1500 defconfig，
   其 `network-2p5g.c` 会做 2.5G 上电序列；**网页不通又无串口 = 变砖不可恢复**。
1. **~~刷 U-Boot~~ → 改为「只清 env」**：当前 U-Boot 已原生支持 统一 UBI 方案，
   **不需要重刷**（因此第 1 节的指纹不匹配问题可绕过）。
   用 Web Failsafe 的 `env-default` / 或擦除 `env` + `env2` 两份（mtd1/mtd2，内容不同，
   必须一起擦），让 U-Boot 写回内置默认 `bootcmd=bootmenu`。
   ⚠️ 此步之前必须已完成第 2 节全部备份 + 第 0 步网页验证。
2. **重启进 Web Failsafe**：`http://192.168.0.1/`（或开机按住 Reset）。
   页面背后是 `/api/job` + `/api/write`：`ubi-attach` / `ubi-rebuild` / `ubi-create` /
   `env-default` / `boot` 等 op；`ubi-rebuild` 会**擦除整个 `ubi_device` MTD**，
   只建 `factory`（8 MiB，RTK_VOL_DATA），然后提示导入 factory 再装系统。
   ⚠️ 一旦执行 `ubi-rebuild`，旧系统与旧卷表就没了，回退只能靠第 2 步的整机备份。
3. **导入 factory**：把本机专属 8 MiB bin 写入 `factory` static 卷（`ubiupdatevol`
   语义，U-Boot 侧按块写 + CRC 回读校验）。
4. **写 fit 卷**：上传 `*-sysupgrade.itb`（或先 `*-recovery.itb` 验证启动）。
   `fit` 卷是 `RTK_VOL_FIRMWARE`，由刷入流程创建、吃满剩余空间。
5. **启动**：`rtk_boot` 会 `ubi part ubi_device` → 把 `fit` 卷整卷读到 `unzip_src`
   （默认 `0x05000000`）→ `fit_check_format` → 若 `rootfs_data` 不存在则自动创建
   （dynamic + autoresize，可用 env `rootfs_data_max` 限制）→ `bootm`。
   **bootargs 不来自 env**，由 FIT/DTB 与 U-Boot 代码统一生成。
6. **首次启动验证**后再装同批 packages、恢复本地修复。

## 4. 验收清单

- [ ] `ubinfo -a` 只有 `factory` / `fit` / `rootfs_data` 三卷（或再有用户自建卷）。
- [ ] `df -h /` 显示 overlay 吃满剩余空间（不再有 152.2 MiB 那套人工布局）。
- [ ] `cat /tmp/sysinfo/board_name` = `youhua,pt1570-r10`（当前 R10-only 范围）。
- [ ] `sysupgrade -T <同型号新 itb>` 通过（`platform_check_image` 白名单已加）。
- [ ] `cat /sys/firmware/devicetree/base/chosen/rootdisk` 非空；`/dev/fit0` 存在。
- [ ] PON 注册 / 上网、四个 LAN 口、WiFi（仅 R10）、LED / Reset 键逐项核对（DTS 验证项）。
- [ ] `fw4 check` 通过（历史上自定义 nft 片段曾导致整体无 NAT）。
- [ ] 时区 Asia/Shanghai、主机名、NTP、`apk update` 能连到同批 packages 源。
- [ ] 连续 3 次冷启动都能进系统。

## 5. 回退路径

- 有 Web Failsafe：重新 `ubi-rebuild` + 导入 factory + 写回旧布局（**注意旧固件是
  `sysupgrade.bin` / 原厂卷号路线，与统一 UBI 方案 不兼容**，需要按当年方案 B+ 的卷表重建）。
- 有整机 mtd 备份：按 mtd 号逐片写回，恢复旧 env（含手写 bootcmd）。
- 最坏情况：XModem 刷 `<board>.fip.bin` 到 fip0，再在 Web Failsafe 里刷完整 `.boot.bin`
  （U-Boot README 记载可能要断电重启一次才会从 fip0 启动）。

## 6. 不能做的事

- 不要把 R10 的 factory bin 刷进 H10，也不要把两台设备的 `/etc/tyfza1-factory/` 互换。
- 不要在统一 UBI 方案上刷 `dreamtekcat@pt1570` 产出的 `sysupgrade.bin`（卷名/格式全不同）。
- 不要在 `DTS_STATUS=experimental` 时用产物刷机；workflow 会额外产出
  `DO-NOT-FLASH-EXPERIMENTAL.txt` 并禁止发布 Release。
- 不要清空 env 之前就把 `ubi_device` 擦掉；顺序反了就没有可引导的 U-Boot 恢复入口。
