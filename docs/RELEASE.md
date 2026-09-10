# Xclip v0.3.0

版本：0.3.0（build 2）。运行要求：macOS 14+。同一应用与 helper 包含 arm64 和 x86_64 两种架构。

## 本次整理

- 集中发布当前 Xclip 实现，移除失效的旧工程、4 个无调用的旧类、废弃 Core Data 模型、空测试模板、旧构建副本、QA 包及本地会话文档。
- 设置 → 通用 → 界面语言支持简体中文 / English，即时生效并在重启后保留。
- 统一历史、截图/OCR、AI/脚本、共享、图片编辑、菜单、状态与错误说明的语言；修复英文筛选栏在窄窗口截断。
- 修复 OCR/截图权限状态刷新与失败恢复，区分读取已有图片的 OCR 和需要屏幕录制权限的截图。
- 保留快速粘贴、来源应用展示、卡片右键编辑、滚轮横向浏览、拖出动画、历史与工作区备份等当前功能。

## 下载与安装

[Release 页面](https://github.com/Anchor-anke/Xclip/releases/tag/v0.3.0) 提供：

- `Xclip-v0.3.0-macOS-universal.dmg`：打开后将 Xclip.app 拖入 Applications。
- `Xclip-v0.3.0-macOS-universal.zip`：直接解压得到 Xclip.app。
- `SHA256SUMS`：在下载目录执行 `shasum -a 256 -c SHA256SUMS` 验证已下载的两个包。

先完整退出旧版再替换应用。沿用原有 CClip 数据位置，不删除用户历史、偏好或钥匙串凭证。

当前使用 ad-hoc 本地签名，未经过 Apple Developer ID 签名和公证。权限项可能与旧构建签名关联；如授权仍无法截图，请按 [BUILDING.md](BUILDING.md) 中的步骤为当前应用恢复授权。已有图片 OCR 无需屏幕录制权限。

## 验证与已知边界

构建、测试与打包方法均保留在仓库脚本中，运行方式见 [BUILDING.md](BUILDING.md)。回归使用合成内容和隔离数据，不附带用户的历史或服务凭证。

最终 0.3.0 构建通过存储、图片处理/OCR、脚本、回环网络、共享、隐私锁、工作区备份、语言、滚轮、卡片菜单和来源记录回归；DMG 与 ZIP 解包后的版本、双架构、签名、许可证和应用哈希一致。

发布前完整 smoke 在锁屏环境中停于快速面板的透明度断言，该轮面板动画复验未通过。其余回归使用已有的 `CCLIP_QUICK_PASTE_TEST_SCOPE=wheel ./scripts/test.sh --network` 范围完成；此范围不包含拖拽载荷、面板定位与显示/隐藏生命周期，不能视为完整快速粘贴验收。代码保留原始完整断言，需在解锁桌面后重新运行完整测试。

语言功能已完成 39 项同步/持久化回归、449 项原生菜单检查、22 项菜单事件检查、25 项编辑命令校验；实际 SwiftUI 初始中文和英文菜单各通过 22 项验证。中英文主页面明暗布局共生成并检查 46 张离屏快照，实际窗口已确认设置及侧栏切换。

最后一轮菜单展开时动态切换语言的视觉复验因界面工具连接中断未完成；初始菜单模型与响应链测试不能代替这一项。macOS 自身窗口、外部错误详情和用户正文不由应用翻译。外部 AI/上传/翻译服务需自行配置。

## 后续发布

1. 在 `src/Xclip.xcodeproj/project.pbxproj` 更新 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。
2. 执行 `./src/build.sh` 和开发指南列出的回归脚本。
3. 执行 `./scripts/package-release.sh`，核对 DMG 挂载后的版本、架构、签名及 ZIP 中的应用。
4. 提交源码到 main，再为同一提交创建版本标签与 GitHub Release，上传根 `dist/` 内的安装包和校验文件。

构建产物与本地验证日志受 `.gitignore` 排除，源代码通过 main 和 Release 标签保存。
