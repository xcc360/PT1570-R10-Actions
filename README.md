# PT1570 云编译项目完整记录（首个 workflow → 2026-11-17）

> 整理日期：2026-11-17
> 仓库：`xcc360/PT1570-R10-Actions`（创建于 2026-11-09，默认分支 main）
> 覆盖范围：PT1570-R10（4×GE）、PT1570-H10-CU（联通 1×2.5GE+3×GE）、PT1500-H10（电信 2.5G）
> 数据来源：GitHub commit 历史（62 条 main 提交 + 5 个分支）、5 个 workflow 头部注释、本地调研/根因报告、历史会话记录

---

## 一、项目演进时间线

### 阶段 0：调研与方案选型（11-09）
- 出两份奠基文档：`云编译资料调研报告`、`FIT统一ABI-云编译补齐方案`。
- 结论：R10（旧 ABI：sysupgrade.bin + ubi_k1/r1）与 H10（新 FIT ABI：sysupgrade.itb + fit 卷）本不兼容；用户选**方案③「统一到 FIT 新 ABI」**，共用一套源码树、各编各的 profile。
- 首批资产落地：`8a19ff5 Create build-pt1570-fit.yml`（11-09 11:57），当天多次增删调整；**按用户决定收窄为 R10-only**（H10 资产标 DORMANT，`PT1570_ALLOW_H10=1` 才放行）。

### 阶段 1：构建链打通（11-10）
- 修 vlmcsd 依赖、preflight 权威路径、PE 固件先于内核编译、Rust musl std。
- `a34ed15`：修 run#10 根因（首次 defconfig 前未初始化 .config）。
- `3983e68`：打包 AP 固件 + 修校准 blob 提取。

### 阶段 2：启动 / 存储 / WAN（11-10~11-12）
- `7ef6d51` / `0f9d28f`：默认 WAN 改绑 pon0 → pon0.1101(802.1Q) + PPPoE，默认开 PON FE。
- `49858d5`：bootloader 不注入 root=，修 FIT rootfs 起不来。
- `a9df1a4`：修刷入态起不来根因——fitblk 4MiB FIT 上限 + ubi_device 只读。
- `9d1ea2b`：删除 R10 DTS 的 /chosen 覆盖块（run15~run22 起不来根因），回到 Run14 已验证形态。
- `4f129eb`：编译期移除上游 pt1500-fip.sh（系统内 sysupgrade 机型校验失败）。

### 阶段 3：驱动与射频基线确立（11-12~11-13）
- `60e6151`：整套替换 rtl_ax_ap 为实测可用的单 PE1 驱动（回退坏的 PE IRAM 方案）。
- `58d941e`：补齐 RFE54 参数表 / TSSI 曲线 / 校准容器。
- `0500134`：apk 源改北大镜像 + 修 UNTRUSTED 签名。
- `65d1d13`：网口修复（lan0 游离 / LED_EPHY0 错绑）。

### 阶段 4：多机型 workflow 铺开（11-14）
- `2dcd730`：新增 PT1500-H10 2.5G 独立 workflow。
- `0b812aa`：新增联通 PT1570-H10-CU 的 U-Boot + firmware workflow。
- `515c39d`：统一命名为 `<型号>-<网口>-<运营商>-<产物类型>`。
- `f1bb7a4`：R10 整合原厂 WiFi RF/beamforming（对齐原厂）。
- `2687088`：移植 PonWRT-TYFZA1 v0.8.5 修 TX 功率上限。

### 阶段 5：H10-CU 硬件适配 + 2.4G 攻坚（11-15~11-16）
- H10-CU：修 2.5G（P6 SerDes）、网口、面板灯、导入原厂备份（15/16/17/18 项）。
- `f22b71f` / `865a8ae`：rtl_ax_ap 加 `rfe50_8192xb` 开关并从 modules.d 开机启用。
- `dd01a75` / `a7e11a7` / `164ab4f` / `e3dbcfe`：2.4G legacy RA 注册 + RSSI 掩码回退；发现驱动是两份独立副本，此前只改了 H10 副本，`e3dbcfe` 同步到 R10。
- `c2445c7`：R10 DTS 转 VERIFIED（真机验证后）。
- `1d39f34`：记录面板 LED 13 个灯位归属。
- `4d36b5f`：main HEAD 停在 U-Boot 灯序 guard（即 RUN #39）。

### 阶段 6：RFE50 前端修复 + 稳定性发布（11-16~11-17）
- 分支 `wifi/rtk-wifi6-stack`：定位 8192XB 2.4G 前端错配（应为 RFE50 无 FEM，误按 RFE54/FEM），完成修复 = RUN #42（commit `625f408`），实机验证可用。
- 分支 `release/wifi-stability-20261117`（commit `d8bd558`，基于 RUN #42）：移植 lu-1991 的两个 hostapd 稳定性参数 + SSID 分频。**R10 = RUN #43、H10 = RUN #12**，均已发布 Release 并刷机验证。
- 11-17：run43 上机确认升级成功、2.4G/5G 各挂 1 台终端稳定在线。

---

## 二、参考资料（本地一手资料，均在 `C:\Users\Xiao\WorkBuddy\Claw\`）

### 奠基方案文档
- `PT1570-R10_H10-云编译资料调研报告.md` — 调研日期 11-09，梳理四个上游仓血缘、三条技术路线、方案选型。
- `PT1570-R10_H10-FIT统一ABI-云编译补齐方案.md` — 方案③完整技术规格（用户所选路线，本项目的源头）。

### 验证 / 根因报告
- `PT1570-R10-真机只读核对报告-20261109.md`、`PT1570-R10-单机型验证报告-20261109.md`
- `PT1570-R10-initramfs启动验证报告-20261110.md`
- `PT1570-R10-刷入后IPv4失效-分析报告-20261111.md`、`PT1570-R10-刷入态启动失败-根因报告-20261112.md`
- `PT1570-UBI空间分析与扩容方案.md`、`PT1570-方案B-UBI布局重构实施报告.md`、`PT1570-新布局重构-可行性与方案.md`、`PT1570-进入原厂系统-现状与方案.md`
- `PT1570-启动慢-排查与提速报告.md`、`PT1570-WiFi-自动开启与稳定性修复报告.md`
- `PT1570-2.4G-TX修复与2.5G上游调研-20261115.md`
- `PT1570-rtk_wifi6整合可行性实测评估-20261116.md` — 换回原厂全栈驱动的评估（结论：成立但工作量以周计，不建议）
- `PT1570-H10-CU与R10-CU差异对比与修复同步方案-20261116.md` — 两板差异矩阵 + 修复可同步性判定
- `HG5585F-CT-云编译搭建指南.md` + `pon-ci-research/` — 早期 HG5585F-CT（Airoha）路线的参考（大部分不能照搬）

### 实物 / 二进制资料
- `D:\ONT\PT1570-R10\BackUp-原厂` — R10 原厂 mtd 备份（含 mtd4 内嵌 DTB、原厂 rtk_wifi6.ko、config.xml、RFE54/RFE50 表）
- `D:\ONT\PT1570-H10\BackUp*` — H10 2026.6 批次原厂备份（确认 2.4G 前端为 RFE50/iFEM）
- 网友固件：`openwrt-...pt1500_h10_2p5g...itb`（13.6MB）、`system.itb` / `system-2p5g.itb` / `system-4ge-20261114.itb`
- lu-1991 固件 C：`...sysupgrade-20261116-1840.itb` — hostapd 稳定性参数来源

---

## 三、上游源（GitHub）

### 核心编译源（直接依赖）
| 仓库 | 分支/锁定 ref | 作用 |
|---|---|---|
| `lyq1996/rtl9617c-openwrt` | `feature/pt1500-h10-openwrt-fixes` @ `20b4cf4` | 完整 OpenWrt 树，三机型 workflow 的共同 base（内核 6.18.55） |
| `lyq1996/rtl9617c-uboot` | `refactor` | FIT ABI 的 U-Boot（rtk_boot + Web Failsafe），R10/H10 U-Boot workflow 来源 |
| `openwrt/openwrt` | `79bc56cb7483` | R10 原 PonWRT 移植层的内核锁定点（6.18.55） |
| `lyq1996/rtl9617c-factory` / `rtl9617c-migration-tools` | — | 校准 blob 提取、迁移工具 |

### 适配基线 / 参考（移植层、对照）
| 仓库 | 作用 |
|---|---|
| `dreamtekcat/PonWRT-TYFZA1` @ `pt1570` | R10 旧 ABI 唯一现成适配基线（调研阶段参考） |
| `LeoooChen/PonWRT-TYFZA1`（上游主线 + issue #18） | 统一重构提议出处；v0.8.5 TX 功率修复来源 |
| `qwe-qaq/*`（PonWRT、rtl9617c-uboot、factory） | fork 对照，确认上游缺陷 |
| `Realtek-OpenWrt/rtl_ax_ap` | 开源 AP 驱动参考 |
| `immortalwrt/packages` / `immortalwrt/luci` + 北大镜像 | feeds 与 apk 源（a53 目录 + 公钥） |
| `lu-1991/PT1570-R10-CI` | 2.4G 兜底思路 + `skip_inactivity_poll`/`disassoc_low_ack` 稳定性参数来源 |
| `pbs05/ponwrt`、`VIKINGYFY/OpenWRT-CI` | 早期 HG5585F-CT 路线参考（多数不通用） |

> 注：上游 `lyq1996/rtl9617c-openwrt` HEAD 已重写为 `13ebc89b`（删掉 tyfza1-*.dtsi），与本锁定的 `20b4cf4` 分叉（ahead 31/behind 104），**三机型 workflow 不能直接切 source_ref**，只逐项回移植。

---

## 四、做了哪些改动（按层面归类）

### 1. 构建系统 / CI
- 5 个 workflow：R10 firmware、H10-CU firmware、PT1500-H10 firmware、R10 U-Boot、H10-CU U-Boot。
- 统一命名 ID、R10-only 范围门控、preflight/Verify 镜像内断言、静态护栏脚本（verify-*.py）、workflow guard（灯序、RFE50、SSID、hostapd）。
- 打包策略：kmod 与固件 vermagic 成对；11-15 起停用同批 packages 发布（`publish_packages=false`）。

### 2. 引导 / 存储（FIT ABI）
- 采用 factory(8MiB) + fit + rootfs_data 布局，产物 sysupgrade.itb。
- 修刷入态起不来：不注入 root=、fitblk 4MiB 上限、ubi_device read-only 放开、写卷前释放 FIT 子镜像。
- 移除上游 pt1500-fip.sh；修 fitblk sysupgrade、系统内更新不保留配置失效。

### 3. 网口 / PON / WAN
- 默认 WAN：pon0.1101 + PPPoE，开 PON FE offload/flow_offloading，VLAN MTU 1500。
- LAN 统一 192.168.1.1/24（含掩码）；迁移旧 192.168.18.1/2.1。
- H10-CU：2.5G P6 SerDes（RTL8221B C22 addr6）、网口4 注册、lan-phys/br-lan 校正；保留 `p6-bringup-off` 逃生开关 + `p6_mode=attempt1g` 实验版。

### 4. WiFi 驱动与射频（改动最密集）
- 整套换回实测可用的单 PE1 rtl_ax_ap 驱动（60 文件）。
- 原厂 RF 整合：YH1570 v52 RFE54 表、LDPC/STBC/beamforming、country=CN。
- PonWRT v0.8.5：清 0xd208/0xd21c 限功率位、txpower ucode、v51 射频表 profile 可切换。
- 自带 AP 固件打包、TSSI 热补偿曲线、校准软链接。
- 2.4G 攻坚：legacy RA 注册、RSSI 掩码回退、两副本同步。
- **RFE50 前端修复（RUN #42）**：8192XB 2.4G 按 RFE50（无 FEM）配置，新增 8 张 RFE50 表；8852C 保持 RFE54/RTK66587_BPF；清旧 `rfe50_8192xb=1` 开关；分 chip 设置增益/RPQ。
- rtk_wifi6 全栈换回：已做五个阶段评估，**未实施**（跨内核大版本 + 跨配置栈，成功率低）。

### 5. LED / 面板
- R10：13 个灯位归属记录；U-Boot 灯序 guard；DTS VERIFIED。
- H10-CU：按原厂 mtd4 内嵌 DTB 逐脚覆盖电源灯/网口灯；98-leds 校正 netdev 绑定。

### 6. LuCI / 软件包
- argon 主题 zh-cn、修 luci.argon rpc -32000、中文 LuCI；apk 北大镜像 + 公钥 + 91 首启脚本；drop vlmcsd。

### 7. 无线配置（最近两次改动）
- **SSID 分频**：型号+频段（R10 / H10-CU 各 -5G / -2.4G），取消双频合一；`scripts/set-band-ssids.py` 依 band 生成 + CI 断言。
- **hostapd 稳定性**：`skip_inactivity_poll=1` + `disassoc_low_ack=0` 写入出厂 conffile 两个 VAP + 首启脚本（R10 扩 96-tuning，H10 新增 99-stability）。
- 加密：曾改纯 WPA2（psk2）做实验，最终刷机后为 5G sae-mixed / 2.4G psk-mixed+ccmp。

---

## 五、可移植性分析

### 高可移植（配置层，跨机型通用）
- **SSID 分频**：`set-band-ssids.py` 按 band 反查，不写死 radio 序号，任何机型只要有两张卡就能用。可移植到 HG5585F-CT 等。
- **hostapd 稳定性参数**：wifi-iface 级通用 UCI 选项，全机型/全驱动通用，已同时落 R10 + H10。
- **WAN/PPPoE/VLAN 1101**：FIT ABI + RTL9617C 平台的通用修法，三机型共用。

### 中可移植（同平台同驱动，需按板核对）
- **WiFi 驱动与射频修复**（RA、RSSI、RFE54 表、功率位清零）：R10 ? H10-CU **完全可同步**——驱动两副本 57/60 逐字节相同、射频标定值逐字节一致、PCIe ID 相同（10ec:c852 / 10ec:0192）。已同步。
- **RFE50 前端修复（RUN #42）**：R10/H10 同为 8192XB + RFE50 前端，可同步；移**植 PT1500-H10 前须先从其原厂备份确认 2.4G 前端拓扑**，不可假定一致。
- **FIT ABI / boot 修复**：三机型共用同一套机制，但 DTS 每机独立（4GE vs 2.5G），不能整块复制。

### 低 / 不可移植（板级或跨代，需单独处理）
- **2.5G 网口（P6 SerDes）**：H10-CU 独有，R10 不适用；上游至 `13ebc89b` 仍未有"一键修好"，且 QX 复位在 CU 上会打死启动链，目前用 bringup-off 保可用。必须分板验证。
- **面板 LED / GPIO**：电源灯、网口灯的 GPIO 与极性各板不同（CU 低号表 vs 电信高号表），逐脚覆盖，不可复用。
- **原厂 rtk_wifi6.ko 全栈**：跨内核（4.4.140 → 6.18.55）+ 跨配置栈（/etc/conf XML → UCI），三个决定性障碍，工作量以周计，建议放弃。
- **原厂备份**：GPT GUID 每机唯一，U-Boot stock 与设备绑定，换机须重新备份。

### 给后续维护的硬规则
1. WiFi 修复默认同步进 R10 + H10 两个驱动副本（历史上曾漏改 R10，已用护栏堵住）。
2. 涉及前端拓扑的改动（RFE50）先在目标机型原厂备份里核实，再动手。
3. 2.5G / LED 属板级，永远单独验证，不与 WiFi 修复混变量。
4. 任何发布都基于实机验证过的分支（当前 = `wifi/rtk-wifi6-stack` 派生的 `release/wifi-stability-20261117`），main 停在 RUN #39 不含 RFE50 修复。
