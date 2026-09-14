# 升级到 Xclip 0.4.1 / Upgrading to Xclip 0.4.1

## 安装与备份

0.4.1（build 5）支持 macOS 14+、Apple Silicon 和 Intel。升级前退出 Xclip，备份整个 `~/Library/Application Support/CClip` 目录和 `~/Library/Preferences/local.cclip.app.plist`；如果自定义了历史位置，同时备份该目录。备份应在应用退出后进行，并包含 SQLite 的 WAL/SHM 文件及附件，不要只复制数据库主文件。

打开 DMG 或完整解压 ZIP，双击 `安装 Xclip.app`，选择原安装位置。安装器校验应用标识、证书和版本，请求所选旧版正常退出，覆盖后重新打开。退出失败会停止，替换失败会尝试恢复旧版。只更新选择的位置，保留历史、附件和配置，不清理其他应用副本。安装器和新版 `Xclip.app` 必须保留在同一目录。

也可完全退出旧版后手动替换应用。覆盖安装器拒绝不同证书、ad-hoc 签名、损坏应用及降级更新；旧 ad-hoc 版本请使用手动替换。发布包使用稳定的本地开发证书，未经过 Developer ID 签名或 Apple 公证。系统可能要求确认打开应用或重新授予权限。

## 数据迁移

新版将较大的正文和原始剪贴板格式保存在附件中，列表按需读取。首次迁移在历史目录保留 `pre-memory-v2.sqlite3`、`pre-memory-v2.sqlite3.attachments.json`；存在配置时还保留 `pre-memory-v2.workflow.json` 和 `pre-memory-v2.settings.json`。迁移按记录提交，失败记录可在排除错误后重试。快照及依赖附件保留用于回退，首次升级应预留额外空间。

归档格式升级到版本 2；新版兼容版本 1 导入。**0.4.0 不能正确读取新版的内容引用和版本 2 归档，不要让新旧版本同时打开同一历史目录。**

## 回退

1. 使用新版导出升级后新增的内容，再退出应用并备份整个当前目录。
2. 优先恢复升级前的完整离线备份。若使用自动迁移快照，先在独立副本中用快照恢复 `history.sqlite3`、workflow/settings，移走该副本中不匹配的 WAL/SHM，并保留快照依赖的旧附件。
3. 用旧版在隔离数据目录核对记录与原始内容，确认后再替换正式数据。覆盖安装器不会执行降级。

## 内存优化的范围

缩略图缓存为 64 MiB；额外编辑撤销图像预算为 128 MiB，关闭贴图的恢复预算为 64 MiB。不持久保存历史时，历史及删除撤销使用 256 MiB 接纳预算，无法容纳时明确报错。活动图像、系统渲染和剪贴板交付不在这些预算内，这些数字不是应用总内存上限。历史仍保留全部轻量索引，长时间真实操作的内存占用需要对应环境验证。

## English

Before upgrading, quit Xclip and back up the entire `~/Library/Application Support/CClip` directory, `~/Library/Preferences/local.cclip.app.plist`, and any custom history location. Include attachments and SQLite WAL/SHM files; do not copy only a live database file.

Open the DMG or fully extract the ZIP. Keep `安装 Xclip.app` (Install Xclip) beside `Xclip.app`, then open the installer and select the existing installation. It verifies identity, certificate and version, requests a normal quit, replaces that copy and reopens it. It stops if quitting fails and attempts rollback if replacement fails. History and settings are retained; other app copies are not removed. Manual replacement after quitting is also supported.

The installer rejects different certificates, ad-hoc signatures, damaged applications and downgrades. Replace old ad-hoc builds manually. This release uses a stable local development certificate, without Developer ID signing or Apple notarization; macOS may require launch confirmation or renewed permissions.

Version 0.4.1 migrates large content into attachments and retains a pre-migration database snapshot, attachment manifest and available configuration snapshots under the names listed above. Allow additional disk space. Archive format 2 supports importing older format 1 archives. **Version 0.4.0 cannot correctly read the new content references or version 2 archives. Never let both versions open the same history directory.**

To roll back, first export new content using 0.4.1, quit and back up the current data. Prefer restoring your complete offline backup from before the upgrade. Test a restored copy in an isolated directory before replacing your active data. Downgrades require manual application replacement.

Cache and undo budgets apply to specific retained content, not the total process memory. Active images, rendering and clipboard delivery use additional memory. Real desktop workflows and long-running memory behavior require separate validation.
