# PT1570 / PT1500 云编译资产仓库

本仓库只存**编译资产与 CI workflow**，不存 OpenWrt 源码。实际固件由 GitHub Actions 拉取上游源码后，在编译期注入本仓库的板级文件、驱动、脚本与配置。

维护范围：PT1570-R10（4×GE）、PT1570-H10-CU（联通 1×2.5GE + 3×GE）、PT1500-H10（电信 2.5G）。

## 构建通道

唯一手动入口：`build-ont-unified.yml`，输入 `board`（`pt1500-h10` / `pt1570-r10` / `pt1570-h10-cu`）与 `test_only`。

| Workflow | 角色 | 说明 |
|---|---|---|
| `build-ont-unified.yml` | 唯一 dispatch 入口 | 按 `board` 分发到下方两个可复用 workflow |
| `build-pt1500-h10.yml` | `workflow_call` | PT1500-H10 固件（upstream refactor 基线，2.5G HisGMII + SerDes + 2500base-x） |
| `build-pt1570-rtw89-unified.yml` | `workflow_call` | R10 / H10-CU 固件（主线 rtw89 + AP firmware，不再注入私有 rtl_ax_ap） |
| `build-uboot-youhua.yml` | 独立 | R10 / H10-CU U-Boot，已发布 |
| `dts-syntax-check.yml` | 独立 | DTS 静态语法检查，改动 DTS 时自动触发 |

所有固件 workflow 都支持 `test_only=true`：只跑注入与静态护栏，不编译、不发版。

> 旧的 `build-pt1570-fit.yml` / `build-ponwrt-pt1570-h10-cu.yml` 及其 base 资产已于 2026-11-25 移除；历史可从 tag `backup/pre-legacy-wf-removal-20261125` 恢复。

## 目录约定

```
.github/workflows/          构建与检查 workflow
boards/pt1500-h10/          PT1500-H10 的 Config / scripts / files
boards/pt1570-r10/          R10 的 Config / scripts / board / files
boards/pt1570-h10-cu/       H10-CU 的 Config / scripts / board / files / firmware / patches
scripts/wb-cache.sh         共享缓存键与时间戳归一化
scripts/wb-build-common.sh  共享下载/准备/包闭包检查等
cu-h10/uboot/               U-Boot 板级描述、defconfig、原厂 stock
refactor/                   历史 refactor 2.5G 实验资产（DTS 静态检查仍引用）
migration/                  历史迁移检查清单与设备预检脚本
docs/                       历史记录
```

## 资产归属规则

1. 三板资产统一放在 `boards/<board>/`；新增机型沿用同构目录，不再在仓库根目录新增机型专属 Config / scripts / overlay。
2. R10 与 H10-CU 走主线 `rtw89`：只注入 DTS、device mk、wireless 配置与 AP firmware，不再注入私有 `rtl_ax_ap` 驱动源码。
3. 机型差异不合并：DTS、LED GPIO、2.5G PHY、校准表、profile 名、SSID 一律按机型独立。
4. 先护栏后编译：资产改动先跑 `test_only`，`boards/<board>/scripts/verify.py` 与 workflow 内断言全部通过后才允许正式编译。
5. 发布必须实机验证：rtw89 实验固件刷机前先进 U-Boot Web Failsafe 备份 `factory`，观察温度并抓 `dmesg | grep -i rtw89` 复核。

## 历史

完整演进时间线、根因分析与上游对照见 [`docs/PROJECT-HISTORY-20261117.md`](docs/PROJECT-HISTORY-20261117.md)。
