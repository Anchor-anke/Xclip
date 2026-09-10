# 贡献指南

感谢参与 Xclip 开发。产品功能见[项目说明](README.md)，环境和命令见[开发指南](docs/BUILDING.md)，发布流程见[发布指南](docs/RELEASE.md)。

## 问题反馈

提交 Issue 前先搜索已有问题。请提供 macOS 版本、Xclip 版本、复现步骤、预期与实际行为；截图或日志应移除剪贴板内容、访问令牌、API 凭证和其他个人信息。

权限问题请同时说明实际运行的应用路径、签名方式，以及完全退出后是否重新授权。不要将“关闭窗口”等同于应用已退出。

## 开发流程

需要包含 macOS 26 SDK 的 Xcode 和 Python 3；应用支持 macOS 14.0 及以上版本。以下命令从仓库根目录执行：

```bash
git switch -c codex/your-change
./src/build.sh
./scripts/test.sh
```

对相关改动追加必要的专项检查：

```bash
./scripts/test-native-language.sh
./scripts/test-editing-commands.sh
./scripts/test-menu-bar.sh
./scripts/test-menu-bar-bundle.sh
```

`./scripts/test.sh --network` 增加本机回环传输测试。有效回归位于 `tests/` 和由应用内部测试入口执行的 `src/OneClip/*Tests.swift`；不要将未被当前入口运行的旧测试目录当作验证依据。

提交 Pull Request 时说明具体问题、修改后的行为、已执行的验证与尚未验证的范围。涉及界面的改动需检查中文与英文、浅色与深色；涉及权限、拖拽或跨应用粘贴的改动需进行真实交互验证。构建或离屏截图成功不能代替这些检查。

## 代码与数据约定

- 保持现有 Swift 风格，为复杂逻辑写必要注释；行为变更应补充能验证实际风险的回归测试。
- 应用自有文案通过统一语言入口提供中英文，切换语言时保留编辑状态。不要翻译用户内容、持久化标识、协议字段或代码。
- `src/OneClip` 是当前源码目录。应用名称、工程和 scheme 为 `Xclip`，内部兼容命名不应随意替换。
- 保持 `local.cclip.app`、既有数据目录和偏好键的兼容性。数据结构变更需验证旧数据读取与备份恢复。
- 测试使用临时数据和隔离应用标识，不操作日常历史、系统 general 剪贴板或真实外部服务凭证。可用 `./scripts/make-qa-app.sh` 创建隔离界面验收包。
- 不提交 `.build/`、`src/dist/`、根目录 `dist/`、个人路径、运行日志或凭证。

## 项目布局

```text
src/OneClip/          当前 Swift 源码及应用内部测试入口
src/Xclip.xcodeproj/  Xcode 工程
src/build.sh         通用应用构建与 helper 打包
tests/               脚本驱动的回归测试
scripts/             构建辅助、测试、隔离 QA 与发布打包脚本
docs/                开发、实现状态与发布说明
```

## 发布资产

构建及验证完成后，运行无参数的 `./scripts/package-release.sh`。脚本从 `src/dist/Xclip.app` 读取版本，将 DMG、ZIP 和 `SHA256SUMS` 写入根目录 `dist/`。这些是 Release 附件，不作为源码提交。签名、公证和资产校验要求见[发布指南](docs/RELEASE.md)，不要将本地打包成功描述成已公开分发或已完成公证。
