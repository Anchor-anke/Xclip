# Xclip

[English](README_EN.md) · 简体中文

Xclip 是一款 macOS 剪贴板管理工具，用于保存、搜索和快速粘贴文本、图片与文件。

## 下载与安装

从 [GitHub Releases](https://github.com/Anchor-anke/Xclip/releases/latest) 下载 DMG 或 ZIP，支持 macOS 14+，同一安装包兼容 Apple Silicon 和 Intel。

当前版本为 **0.4.1（build 5）**。设置 → 通用 → 界面语言可选择简体中文或 English，立即生效并记住选择。

DMG / ZIP 同时包含 `安装 Xclip.app` 与 `Xclip.app`：双击安装器，选择原安装位置，即可请求旧版正常退出、覆盖并重新打开，保留历史和配置。旧版无法正常退出时会停止安装；不会自动清理其他副本。ZIP 需先完整解压，两个应用应保留在同一目录。也可完全退出旧版后，手动拖放 `Xclip.app` 到原位置并选择「替换」。升级前备份数据，迁移与回退方法见[升级说明](docs/UPGRADING.md)。

0.4.1 发布包使用稳定的本地开发证书，尚未经过 Developer ID 签名与 Apple 公证。截图需要屏幕录制权限；已有图片的 OCR 不需要屏幕录制权限。安装与授权说明见[开发指南](docs/BUILDING.md)。

## 当前功能

- 保存与搜索剪贴板历史，支持文本、图片、文件和来源应用记录。
- 按 `⌘;` 打开快速粘贴面板，使用滚轮横向浏览卡片，拖出内容时面板伴随动画隐藏。
- 支持拖拽中按鼠标右键取消，无需先松开左键；快速面板会在取消后恢复。
- 大内容按需读取，列表使用有容量限制的缩略图缓存；面板关闭后释放预览。快捷键支持清除并在重启后保持停用。
- 右键卡片修改内容、收藏、置顶、复制、粘贴和删除；支持删除撤销。
- 使用 SQLite 和独立附件保存历史，提供备份、恢复与自定义存储位置。
- 提供栈粘贴、快捷回复、截屏标注、图片识字，以及可配置的 AI、脚本、局域网共享、上传和翻译工具。
- 按截屏快捷键直接进入选区与浮动标注栏，添加箭头、文字、马赛克后复制或保存；在“设置 → 快捷键 → 截屏”修改组合键。详见[截图操作说明](docs/screenshot-annotation.md)。
- 提供长截图、录屏与 MP4/GIF/WebP 导出、贴图、表格/条码识别、本地公式渲染，以及配置服务后的翻译和图片公式识别。完整入口与验证边界见 [0.4.0 截图工作流](docs/pixpin-complete-validation.md)。
- 简体中文与 English 界面即时切换，统一工具页、菜单与错误提示的语言。

功能范围和已知限制见[实现状态](docs/implementation-status.md)，操作方法见[开发与运行说明](docs/BUILDING.md)。AI、上传和翻译服务需要自行配置。

仓库还包含独立的 [Windows 核心预览版](windows/README.md)。它仍需 Windows 实机验收；本次 Release 下载包面向 macOS。

## 构建与运行

运行需要 macOS 14+；构建需要包含 macOS 26 SDK 的 Xcode、Python 3 和 CMake。在项目根目录运行：

```bash
./src/build.sh
open src/dist/Xclip.app
```

默认生成 Apple Silicon / Intel 通用应用，优先复用已安装版本的签名证书；尚未使用证书时自动选择唯一可用身份，没有有效身份时使用 ad-hoc 签名。已使用的证书不可用或有多个待选身份时停止构建。Xcode 工程为 `src/Xclip.xcodeproj`，scheme 为 `Xclip`。详细构建、隔离测试和权限说明见[开发指南](docs/BUILDING.md)。

执行 `./scripts/package-release.sh` 将使用稳定证书签名的当前构建及覆盖安装器整理为根目录 `dist/` 中的 DMG、ZIP 与 `SHA256SUMS`。可用 `XCLIP_PACKAGE_OUTPUT_DIR` 指定候选包输出目录，避免覆盖已有发布资产。发布记录及验收边界见[发布说明](docs/RELEASE.md)。

## 许可

[MIT 许可证](LICENSE) · [版权声明](NOTICE.md)
