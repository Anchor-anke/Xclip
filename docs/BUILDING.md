# Xclip 开发与验证

本文中的命令均从仓库根目录执行。产品功能见[项目说明](../README.md)，发布流程见[发布指南](RELEASE.md)。

## 环境要求

- 运行环境：macOS 14.0 或更高版本。
- 构建环境：包含 macOS 26 SDK 的 Xcode，且命令行工具指向该 Xcode。原生 Liquid Glass 使用 macOS 26 API，较早的运行系统使用兼容材质。
- Python 3，用于将当前 Swift 源文件同步到 Xcode 工程。
- CMake，用于构建随应用分发的 libwebp 动图编码 helper。

项目使用系统框架，以 Swift 5 语言模式构建，无需安装第三方 Swift 包。

## 构建与运行

```bash
./src/build.sh
open src/dist/Xclip.app
```

脚本默认使用 `swiftc` 和 `actool` 从当前源码、原始资产编译 Release 通用应用，同时构建 JavaScript 与 WebP helper、复制中英文资源与许可证。输出固定为 `src/dist/Xclip.app`，应用主程序名为 `Xclip`，源码目录保留 `src/OneClip`。Xcode 工程仍是版本、部署目标和资源名称的配置来源。

安装时先复制到同一磁盘的暂存目录并验证签名，再原子替换正式版；安装后再次验签，失败则恢复旧版。成功后自动删除本仓库已知构建目录中的旧 Xclip 正式版、体验版和 QA 应用副本；同时检查 `~/Desktop/Xclip.app`、`~/Applications/Xclip.app` 和 `/Applications/Xclip.app`，仅清理标识及证书相同、版本不高于新版且签名资源完整的副本。不同身份、更新版本、符号链接和含未知文件的副本会保留。源码、设置、剪贴板历史、测试数据与恢复目录会保留。正在运行的应用不会被覆盖或删除：脚本会提示退出后重试，已构建的新包会保留。

```bash
CONFIGURATION=Debug ./src/build.sh
```

也可在 Xcode 中打开 `src/Xclip.xcodeproj`，选择 `Xclip` scheme 查看和调试源码。需要完整可运行应用时使用 `src/build.sh`，以确保脚本 helper 已打包。

| 变量 | 用途 | 默认值 |
| --- | --- | --- |
| `CONFIGURATION` | 构建配置 | `Release` |
| `XCLIP_DERIVED_DIR` | Xcode 构建目录 | `.build/DerivedData` |
| `XCLIP_OUTPUT_DIR` | 应用输出目录 | `src/dist` |
| `XCLIP_CODE_SIGN_IDENTITY` | 已有代码签名身份 | 复用安装身份或唯一可用身份；无身份时 ad-hoc |
| `XCLIP_BUILD_METHOD` | `direct` 或 `xcode` 编译方式 | `direct` |
| `XCLIP_INSTALL` | `0` 仅构建验签；`1` 构建并安装 | `1` |

构建目录、输出目录和签名身份仍兼容对应的 `CCLIP_*` 旧变量；同时设置时优先使用 `XCLIP_*`。显式自定义输出目录按独立构建处理，只更新该目录的应用，不清理其他目录。自定义路径建议使用绝对路径，并以脚本最后打印的 `Built` 路径为准。`XCLIP_DERIVED_DIR` 仅用于 `XCLIP_BUILD_METHOD=xcode`。

需要先验证新包再安装时：

```bash
XCLIP_INSTALL=0 ./src/build.sh
# 完全退出正在运行的 Xclip，再使用上一步打印的实际路径：
python3 scripts/install-local.py --source /实际暂存路径/Xclip.app
```

安装器支持 `--dry-run` 只显示计划。自定义目的地必须同时指定 `--destination /路径/Xclip.app --no-cleanup`，不会清理其他构建副本。默认安装只检查上文列出的项目生成目录与已知应用路径，不扫描其他目录；外部副本须通过标识、证书、版本及资源完整性检查才会清理。

`.build/`、`src/dist/` 和仓库根目录 `dist/` 都是生成目录，不作为源码提交。

## 发布打包

打包脚本默认使用 `src/dist/Xclip.app`，需要先完成构建与验证。运行：

```bash
./scripts/package-release.sh
```

也可通过 `XCLIP_PACKAGE_APP=/完整路径/Xclip.app ./scripts/package-release.sh` 打包尚未安装的已验签候选版本，不替换正在使用的本地应用。

打包脚本从应用的 `Info.plist` 读取版本，将发布用 DMG、ZIP 和 `SHA256SUMS` 写入仓库根目录 `dist/`；这与默认应用输出目录 `src/dist/` 不同。版本 0.4.0 的文件名为 `Xclip-v0.4.0-macOS-universal.dmg` 和 `Xclip-v0.4.0-macOS-universal.zip`。上传 Release 前可在输出目录校验文件：

```bash
(cd dist && shasum -a 256 -c SHA256SUMS)
```

打包、上传 Release、Developer ID 签名和 Apple 公证是不同步骤。0.4.0 发布包使用稳定的本地开发证书，未经过 Developer ID 签名和 Apple 公证。打包脚本不会重新签名，生成的安装包保留输入应用的签名。发布状态与资产说明见[发布指南](RELEASE.md)。

## 签名与权限

持续在同一台 Mac 上构建和更新时，应保留稳定的代码签名身份。证书和私钥由开发者的钥匙串管理，不将证书导出文件、私钥或访问口令写入仓库。本地开发证书不等同于 Developer ID 分发或 Apple 公证，也不会让其他用户的 Mac 自动信任安装包。

未显式指定证书时，构建脚本首先复用正式安装版本的证书；已使用的证书或私钥不可用会停止更新，不回退为临时签名。尚未安装证书签名版且只有一个有效代码签名身份时，自动使用该身份；多个待选身份需要明确指定。没有有效身份时仍可构建 ad-hoc 版本，但每次更新都可能要求重新授权。固定安装路径和清理旧包不能代替稳定签名。

需要检查身份或明确指定证书时：

```bash
security find-identity -v -p codesigning
XCLIP_CODE_SIGN_IDENTITY='已有代码签名证书名称或 SHA-1 指纹' ./src/build.sh
```

脚本将同一身份用于 helper 和主应用。指定身份不可用或签名失败时停止构建，不会回退为临时签名；脚本不会创建证书、修改钥匙串信任或重置系统权限。

首次用 `codesign` 访问私钥时，macOS 可能要求用户确认钥匙串访问。从旧 ad-hoc 签名首次换成此证书签名后，还需要为固定路径下的新应用完成一次屏幕录制授权；钥匙串访问确认不等于屏幕录制授权。

2026-09-11 的开发机升级测试使用同一签名身份构建了两个不同 CDHash 的版本，签名要求保持相同。第二轮安装后未重置屏幕录制权限，实际框选、箭头、中文文字、马赛克与保存通过，系统的预检和实际捕获请求均允许。这验证了该次升级的授权延续，不保证所有未来版本、系统更新或证书更换后永久免授权。

Apple 说明默认签名要求用于让系统将后续版本识别为同一个应用；ad-hoc 身份只对应一份具体代码。[TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) 与 [ScreenCaptureKit 官方答复](https://developer.apple.com/forums/thread/819406) 描述了更新与隐私授权的关系。持续使用时应保留同一证书与私钥；证书到期、丢失或主动更换身份时，需要重新验证更新和授权流程。

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

0.4.0 还包含 `test-capture-complete.sh`：高级标注、贴图、长截图、录屏/动图与本地公式检查。Vision、HEIC、WebKit、音频编解码测试需要 macOS 图形会话和系统服务访问，受限沙箱可能阻止这些服务；测试只处理生成的图片/音频及命名剪贴板，不请求屏幕或麦克风权限。

录屏 WebP helper 由 `scripts/build-recording-webp.sh` 构建，首次从官方地址下载固定 SHA256 的 libwebp 1.6.0 源码，随后可复用本地源码。构建机需要 CMake 和 Xcode 命令行工具。应用内包含双架构 helper、静态依赖与许可证，使用者无需安装 CMake、ffmpeg 或 cwebp。公式所需 KaTeX 0.18.7 文件和字体位于 `src/Resources/Formula`，直接构建与 Xcode 构建均打包这些资源。

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

本地 URL 接口使用 `xclip://`，并兼容 `cclip://` 与 `oneclip-dev://`。支持 `show`、`search?q=...`、`add?text=...`、`stack?text=...` 和 `capture`；接收内容需在应用内确认，外部 `capture` 请求也需要本机确认后才进入选区标注。应用内截屏按钮和自定义截屏快捷键可直接触发。接口拒绝未知命令、重复参数、空内容和超过 1 MB 的输入，不接受任意文件路径或脚本。
