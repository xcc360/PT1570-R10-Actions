# PT1570 / PT1500 云编译资产仓库

本仓库只存**编译资产与 CI workflow**，不存 OpenWrt 源码。实际固件由 GitHub Actions 拉取上游源码后，在编译期注入本仓库的板级文件、脚本与配置。

维护范围：PT1570-R10（4×GE）、PT1570-H10-CU（联通 1×2.5GE + 3×GE）、PT1500-H10（电信 2.5G）。

## 构建通道

仓库现在只有 **2 条 workflow**：

| Workflow | 角色 | 说明 |
|---|---|---|
| `build-ont-unified.yml` | 固件唯一 dispatch 入口 | 三板同入口；`board` 可选单板、任意两板、三板全选 |
| `build-uboot-youhua.yml` | U-Boot 独立入口 | `board=both` 一次构建 R10 / H10-CU 两块板 |

`build-ont-unified.yml` 的 `board` 选项：

- `all`：三板全选（三选三）
- `pt1570-r10+pt1570-h10-cu`、`pt1570-r10+pt1500-h10`、`pt1570-h10-cu+pt1500-h10`：三种双板组合（三选二）
- 三个单板值：`pt1570-r10`、`pt1570-h10-cu`、`pt1500-h10`

通过 API dispatch 还可以用 `+` 拼接任意组合（例如 `pt1570-r10+pt1500-h10+pt1570-h10-cu`），`select` job 会去重并展开为 matrix；单板走 `jobs.pt1500` 或 `jobs.rtw89`，双板/三板由两个 job 并行执行，各自独立 artifact 与 release tag。

常用输入：

- `source_ref`：留空时用各板默认上游 commit；填了则覆盖全部所选板。
- `test_only`：默认 `true`，只跑注入、defconfig、静态护栏并上传 `.config`。
- `create_release`：正式构建后发布 Release。
- `publish_packages` / `packages_repo_url` / `apk_mirror_base` / `apk_repo_key_url`：仅 PT1500-H10 使用。

U-Boot workflow 与固件入口分离：板型命名与 Release 语义不同，且 U-Boot stock 是设备专用备份。

## 目录约定

```
.github/workflows/
  build-ont-unified.yml       固件唯一入口（内含 PT1500 与 rtw89 两条 job）
  build-uboot-youhua.yml      U-Boot 入口
boards/pt1500-h10/            PT1500-H10 的 Config / scripts / files
boards/pt1570-r10/            R10 的 Config / scripts / board / files
boards/pt1570-h10-cu/         H10-CU 的 Config / scripts / board / files / firmware / patches
scripts/wb-cache.sh           共享缓存键与时间戳归一化
scripts/wb-build-common.sh    共享下载/准备/包闭包检查等
uboot/stocks/<board>/         设备专用原厂 mtd0 备份
uboot/tools/                  CU / R10 灯表静态护栏
migration/                    历史迁移检查清单与设备预检脚本
docs/                         历史记录
```

## 资产归属规则

1. 三板资产统一放在 `boards/<board>/`；新增机型沿用同构目录，不再在仓库根目录新增机型专属 Config / scripts / overlay。
2. R10 与 H10-CU 走主线 `rtw89`：只注入 DTS、device mk、wireless 配置与 AP firmware，不再注入私有 `rtl_ax_ap` 驱动源码。
3. 机型差异不合并：DTS、LED GPIO、2.5G PHY、校准表、profile 名、SSID 一律按机型独立。
4. 先护栏后编译：资产改动先跑 `test_only`；`boards/<board>/scripts/verify.py`、workflow 内断言与上游 defconfig 检查全部通过后才允许正式编译。独立的 `dts-syntax-check.yml` 已取消，DTS 静态检查并入各板护栏。
5. 发布必须实机验证：rtw89 实验固件刷机前先进 U-Boot Web Failsafe 备份 `factory`，观察温度并抓 `dmesg | grep -i rtw89` 复核。
6. U-Boot 不保存上游板级副本：只保留每机唯一的 stock 与灯表护栏；stock 摘要直接读上游 board json。
7. 三机型的 `files/etc/apk/keys/` 统一内置两把软件源公钥：`openwrt-snapshots.pem`（OpenWrt 官方 snapshot 源）与 `immortalwrt-25.12.pem`（ImmortalWrt 25.12 源）。这样无论固件默认源指向 OpenWrt snapshot（R10 / H10-CU）还是 ImmortalWrt 25.12 北大镜像（PT1500-H10），apk 安装软件时都不会因缺公钥报 `UNTRUSTED signature`。

## 历史

完整演进时间线、根因分析与上游对照见 [`docs/PROJECT-HISTORY-20261117.md`](docs/PROJECT-HISTORY-20261117.md)。
已被取代的旧 workflow / 资产可从备份 tag 恢复：
`backup/pre-single-entry-20261125`、`backup/pre-uboot-unify-20261125`、`backup/pre-legacy-wf-removal-20261125`、`backup/pre-consolidation-main-20261125`。
