# PT15xx 上游同步策略（2026-11-27 起）

## 策略

三块板（PT1500-H10、PT1570-H10-CU、PT1570-R10）**统一锁定同一个已验证的 OpenWrt 上游提交**，紧跟 `lyq1996/rtl9617c-openwrt@refactor` HEAD，不再长期停留在旧基线。

U-Boot 独立跟踪 `lyq1996/rtl9617c-uboot@main`，仅在真实有新提交且验证通过后更新。

**PON/LuCI feed（`crysister/rtl9617c-packages@main`）不锁 SHA、紧随上游默认分支更新**（2026-11-28 用户决定）：workflow 保持 `feeds update -a` 原样，不固定 commit。feed 变化靠编译后的 `test_only=true` 全板断言与产物校验兜底，而不是靠 SHA 钉死。因此每次正式编译前建议先看上游 feed 是否有新提交（尤其新增包、包名变化、LuCI 资源冲突），有变化就先跑一次 `test_only=true`，通过后再正式编译。

## 固定点

| 项目 | 位置 | 当前固定 ref |
|---|---|---|
| 三板 OpenWrt 源码 | `.github/workflows/build-ont-unified.yml` 的 `DEFAULT_REF`（共 3 处，必须一致） | `1e265329e20873d64ee05d3c95bc59b4b10ce6a4` |
| U-Boot | `.github/workflows/build-uboot-youhua.yml` 的 `uboot_ref` | `ad056996854cfd7ea009f6a0d05a0f86f045b800` |

`source_ref` / `uboot_ref` 工作流输入仍可临时覆盖，用于试验或回退；默认必须等于上表。

## 上游更新时的标准流程

1. 检查上游：`python3 scripts/check-upstream.py`（比对上游 HEAD 与仓库固定点，有差距返回 1）。
2. 看 diff：重点确认 rtw89/无线、PON/feed、2.5G 驱动、DTS、config-6.18、feeds.conf.default 是否改变。
3. **先验证，再改默认值**：
   - 用 workflow 的 `source_ref` 输入（40 位 SHA）跑 `test_only=true`；
   - 建议 `board=all`，至少也要覆盖所有受影响板；
   - 只有全部 job success、日志出现 `ALL ASSERTIONS PASSED` 才继续。
4. 把三处 `DEFAULT_REF` 一起改成该 SHA；同步更新 board `verify.py` 的基线注释和 H10 release note 文案（release note 已改为使用 `$SOURCE_HASH`，无需手改）。
5. 再跑一次**不带 source_ref 覆盖**的 `test_only=true`，确认默认配置也通过。
6. 正式编译 `test_only=false`，按需 `create_release`；发布说明里记录 source SHA。
7. 实机回归：R10/CU 看 WiFi 双卡枚举、hostapd、5G/2.4G、多 SSID、发射功率、`dmesg | grep -i rtw89`；H10 看 2.5G link、PON 注册、面板灯、WAN/VLAN 1101、APK 源。

## 兼容层原则

- 三板源码统一后，板级资产仍各管各的：`boards/<board>/`。
- H10 的 PON/LuCI 资产在 2026-11-27 后来自 `crysister/rtl9617c-packages` feed；`apply.sh` 同时搜索源码树与 `feeds/rtl9617c/`，保证短期回退也能工作。
- H10 的 P6 驱动标记 `ni_te_flow.c` / `ni_p6.c` 二选一；上游再改名时只改这一处。
- 面板灯校准脚本 `apply-dts-leds-fix.sh` 只匹配顶层唯一 `leds` 节点；上游 DTS 结构变化时它会 fail 并要求人工复核，不要绕过。
- 缓存键含源码 SHA 前 12 位，换基线自动分桶，`dl` 缓存可复用；不要手工混用不同基线的 build_dir/staging_dir。

## 禁止事项

- 不要把某块板单独留在很旧的基线（H10 曾落后 39 个提交），除非有明确实机阻断原因并记录在此文件。
- 不要在 `test_only` 失败时直接改默认值或关掉断言。
- 不要用私有 `rtl_ax_ap` 驱动替代主线 `rtw89`。
