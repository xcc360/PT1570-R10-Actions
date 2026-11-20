# PT1570 / PT1500 云编译资产仓库

本仓库只存**编译资产与 CI workflow**，不存 OpenWrt 源码。实际固件由 GitHub Actions 拉取上游源码后，在编译期注入本仓库的板级文件、驱动、脚本与配置。

维护范围：PT1570-R10（4×GE）、PT1570-H10-CU（联通 1×2.5GE + 3×GE）、PT1500-H10（电信 2.5G）。

## 构建通道

| Workflow | 用途 | 源码基线 | 状态 |
|---|---|---|---|
| `build-pt1570-fit.yml` | R10 固件 | base `20b4cf4` 单 PE1 | 稳定版，已实机验证 |
| `build-ponwrt-pt1570-h10-cu.yml` | H10-CU 固件（base） | base `20b4cf4` | 稳定版，已实机验证；2.5G 仍为旧 sgmii/hsgmii 架构 |
| `build-pt1500-h10.yml` | PT1500-H10 固件 | upstream `refactor` | 2.5G HisGMII + SerDes + 2500base-x，已完整编译成功 |
| `build-pt1570-h10-cu-refactor.yml` | H10-CU 固件（refactor 2.5G 实验通道） | `ae4aeac45a70` | test_only 通过；未实机验证，不与 base 通道混用 |
| `build-uboot-youhua.yml` | R10 / H10-CU U-Boot | `lyq1996/rtl9617c-uboot@refactor` | 已发布 |
| `dts-syntax-check.yml` | DTS 静态语法检查 | — | 改动 DTS 时自动触发 |

所有固件 workflow 都支持 `test_only=true`：只跑注入与静态护栏，不编译、不发版。

## 目录约定

```
.github/workflows/   构建与检查 workflow
board/               单板资产：DTS、devices、共用 WiFi 驱动单一源
files/               R10 rootfs overlay（files/ 即默认机型）
files-h10/           PT1500-H10 专用 overlay
files-common/        多机型逐字节相同的公共 rootfs 文件（先于机型 overlay 拷贝）
cu-h10/fw/           H10-CU base 资产：Config、customize、overlay、板级 DTS/PCIe/LED/ne-glue
refactor/            refactor 2.5G 通道资产：Config、customize、DTS、patches、首启文件
patches/             只放真正被编译期脚本引用的 patch
scripts/             跨 workflow 共用脚本与护栏
migration/           迁移检查清单与设备预检脚本
uboot-stocks/        U-Boot 原厂 stock（base64）
docs/                历史记录与说明文档
```

## 资产归属规则

1. **WiFi 驱动只有一份真源**：`board/wifi/rtl_ax_ap`。R10、H10-CU、CU refactor 三条通道都从这里取；`scripts/verify-wifi-parity.py` 保证不再出现第二份副本。
2. **公共 rootfs 文件只有一份真源**：`files-common/`。四套 overlay 里逐字节相同的公钥、rpcd、sysupgrade 钩子等统一放这里，机型 overlay 只保留差异项。
3. **机型差异不合并**：DTS、LED GPIO、2.5G PHY、校准表、profile 名、SSID 一律按机型独立，禁止跨机型复制粘贴。
4. **先护栏后编译**：任何资产改动先跑 test_only；`preflight.sh`、`verify-*.py` 与 workflow 内断言全部通过后才允许正式编译。
5. **发布必须实机验证**：refactor 2.5G 通道目前只到 test_only，未刷机验证，不得当作稳定版发布。

## 历史

完整演进时间线、根因分析与上游对照见 [`docs/PROJECT-HISTORY-20261117.md`](docs/PROJECT-HISTORY-20261117.md)。
