# Xclip 开发与验证

本文中的命令均从仓库根目录执行。产品功能见[项目说明](../README.md)，发布流程见[发布指南](RELEASE.md)。

## 环境要求

- 运行环境：macOS 14.0 或更高版本。
- 构建环境：包含 macOS 26 SDK 的 Xcode，且命令行工具指向该 Xcode。原生 Liquid Glass 使用 macOS 26 API，较早的运行系统使用兼容材质。
- Python 3，用于将当前 Swift 源文件同步到 Xcode 工程。

项目使用系统框架，以 Swift 5 语言模式构建，无需安装第三方 Swift 包。

## 构建与运行

```bash
./src/build.sh
open src/dist/Xclip.app
```

脚本默认执行 Release 构建，生成 Apple Silicon / Intel 通用应用，并将通用 JavaScript helper 放入应用包。输出为 `src/dist/Xclip.app`，应用主程序名为 `Xclip`，源码目录保留 `src/OneClip`。构建脚本会同步 `src/Xclip.xcodeproj` 的源码引用、复制许可证文件，并验证代码签名。

```bash
CONFIGURATION=Debug ./src/build.sh
```

也可在 Xcode 中打开 `src/Xclip.xcodeproj`，选择 `Xclip` scheme 查看和调试源码。需要完整可运行应用时使用 `src/build.sh`，以确保脚本 helper 已打包。

| 变量 | 用途 | 默认值 |
| --- | --- | --- |
| `CONFIGURATION` | 构建配置 | `Release` |
| `XCLIP_DERIVED_DIR` | Xcode 构建目录 | `.build/DerivedData` |
| `XCLIP_OUTPUT_DIR` | 应用输出目录 | `src/dist` |
| `XCLIP_CODE_SIGN_IDENTITY` | 已有代码签名身份 | `-`，即 ad-hoc 签名 |

构建目录、输出目录和签名身份仍兼容对应的 `CCLIP_*` 旧变量；同时设置时优先使用 `XCLIP_*`。并行开发时应指定独立目录，避免替换正在运行的应用。自定义路径建议使用绝对路径，并以脚本最后打印的 `Built` 路径为准。

`.build/`、`src/dist/` 和仓库根目录 `dist/` 都是生成目录，不作为源码提交。

## 发布打包

打包脚本不接受参数，需要先用 `./src/build.sh` 生成 `src/dist/Xclip.app`。完成相应验证后运行：

```bash
./scripts/package-release.sh
```

打包脚本从应用的 `Info.plist` 读取版本，将发布用 DMG、ZIP 和 `SHA256SUMS` 写入仓库根目录 `dist/`；这与默认应用输出目录 `src/dist/` 不同。版本 0.3.0 的文件名为 `Xclip-v0.3.0-macOS-universal.dmg` 和 `Xclip-v0.3.0-macOS-universal.zip`。上传 Release 前可在输出目录校验文件：

```bash
(cd dist && shasum -a 256 -c SHA256SUMS)
```

打包、上传 Release、Developer ID 签名和 Apple 公证是不同步骤。0.3.0 使用 ad-hoc 签名，未完成 Apple 公证；生成安装包不会改变这一签名状态。发布状态与资产说明见[发布指南](RELEASE.md)。

## 签名与权限

未指定证书时使用 ad-hoc 临时签名。重新构建后，旧的屏幕录制授权可能不再匹配当前应用。持续开发可以沿用钥匙串中已有的 Apple Development 或 Developer ID Application 签名身份：

```bash
security find-identity -v -p codesigning
XCLIP_CODE_SIGN_IDENTITY='已有代码签名证书名称或 SHA-1 指纹' ./src/build.sh
```

脚本将同一身份用于 helper 和主应用。指定身份不可用或签名失败时停止构建，不会回退为临时签名；脚本不会创建证书、修改钥匙串信任或重置系统权限。

若系统设置中已授权，但当前应用仍无法截图：

1. 从 Xclip 菜单退出应用；关闭窗口不等于结束菜单栏进程。
2. 在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中移除旧的 Xclip/CClip 授权项。不同 macOS 版本可能显示为“屏幕录制”。
3. 添加并开启当前实际运行的应用。默认路径为本仓库下的 `src/dist/Xclip.app`，避免选中其他目录中的旧副本。
4. 重新打开同一应用；若系统要求“退出并重新打开”，按提示重启后再尝试截图。

屏幕截图和屏幕识字需要屏幕录制权限；对已有图片执行 OCR 不需要。自动粘贴、全局键盘事件和划词等功能还需要辅助功能权限，可从设置页打开对应的系统设置。应用内的语言选择不会修改 macOS 系统界面的语言。

## 自动化测试

先构建应用，再运行当前回归入口：

```bash
./src/build.sh
./scripts/test.sh
```

可选的本机回环传输测试：

```bash
./scripts/test.sh --network
```

`test.sh` 包含存储、图片处理与 OCR、脚本隔离和超时、请求构造与解析、上传/翻译、隐私锁状态及应用 smoke 回归。上传和翻译请求使用拦截会话；`--network` 增加本机回环收发测试，不请求真实外部服务。

应用 smoke 使用复制后的隔离 bundle ID 和临时数据目录，覆盖命名剪贴板、工作区备份、URL 解析及语言切换。可通过 `XCLIP_TEST_APP` 指向其他构建的 `Xclip.app/Contents/MacOS/Xclip`。测试使用命名剪贴板，不以系统 general 剪贴板作为测试输入或输出。

以下专项检查独立运行，不包含在 `test.sh` 中：

```bash
./scripts/test-native-language.sh
./scripts/test-editing-commands.sh
./scripts/test-menu-bar.sh
./scripts/test-menu-bar-bundle.sh
```

- 原生语言检查：验证双向切换、菜单动作、快捷键和用户内容保持，以及菜单跟踪事件。
- 编辑命令检查：验证响应链派发与动作可用状态。
- 菜单栏检查：检查入口生命周期、Dock 模式切换、窗口隐藏与恢复；测试会短暂创建自身窗口和菜单栏入口。
- 应用包菜单栏检查：通过 LaunchServices 启动隔离测试应用。加 `--build-only` 可只编译、打包和验签，不启动界面。

有效测试源码位于根目录 `tests/`，以及由应用内部测试入口调用的 `src/OneClip/*Tests.swift`。Xcode scheme 构建成功不代表这些脚本已运行。

Vision、命名剪贴板、AppKit 和监听端口依赖正常的 macOS 服务环境。受限环境拒绝服务时，应记录失败原因，区分环境问题与断言失败。离屏截图与窗口几何检查用于布局和状态验证，不能替代真实屏幕权限、菜单栏可见性、拖拽或跨应用粘贴验收。

## 隔离界面验收

```bash
./scripts/make-qa-app.sh
open .build/Xclip-QA.app
```

该脚本从 `src/dist/Xclip.app` 创建 QA 包，使用独立 bundle ID `local.cclip.qa` 和固定的 `.build/qa-data` 数据目录。QA 启动不会注册全局键盘事件或启动历史监控，适合检查语言切换、界面布局和交互。

`--smoke-test` 和 `--render-snapshots` 是内部入口。自建测试入口必须使用隔离应用标识与数据目录；仅设置数据目录不足以隔离 UserDefaults 偏好。数据目录变量继续使用 `CCLIP_DATA_DIR`，离屏渲染还需 `CCLIP_RENDER_DIR`，可用 `CCLIP_RENDER_LANGUAGES=zh,en` 在同一视图中验证语言切换。

## 数据与命名兼容

- 应用名、工程和 scheme 为 `Xclip`；`src/OneClip`、部分内部类型及 helper 名保留兼容命名。
- 普通应用沿用 bundle ID `local.cclip.app`、默认数据目录 `~/Library/Application Support/CClip` 和既有偏好键，继续读取原有历史与设置。
- 历史可迁移到自定义目录；工作流配置仍保存在默认数据目录。通过设置迁移时保留原目录，确认新目录可用后再自行处理旧副本。
- 完整备份包含历史、附件与工作区配置，不包含钥匙串凭证。导入不会替代系统权限授权，导入脚本保持禁用。
- 设置中的界面语言会立即生效并保存；用户复制内容、自定义名称、代码和服务响应保持原值。
- 历史锁保护应用界面，不等同于数据库加密。

本地 URL 接口使用 `xclip://`，并兼容 `cclip://` 与 `oneclip-dev://`。支持 `show`、`search?q=...`、`add?text=...`、`stack?text=...` 和 `capture`；接收内容需在应用内确认，`capture` 只打开工具，不自动截屏。接口拒绝未知命令、重复参数、空内容和超过 1 MB 的输入，不接受任意文件路径或脚本。
