# Xclip 源码

Xclip 使用 SwiftUI、AppKit、SQLite 及 macOS 系统框架。产品功能见[项目说明](../README.md)，完整构建、权限、测试和隔离运行说明见[开发指南](../docs/BUILDING.md)。

## 构建与运行

运行需要 macOS 14.0 或更高版本。构建需要包含 macOS 26 SDK 的 Xcode、Python 3 和 CMake；原生 Liquid Glass 在较早的 macOS 上使用兼容材质。

以下命令从仓库根目录执行：

```bash
./src/build.sh
open src/dist/Xclip.app
```

脚本默认执行 Release 构建，生成 Apple Silicon / Intel 通用应用，包含 `Xclip` 主程序、JavaScript 与 WebP helper，以及离线公式渲染资源。未指定签名身份时，优先复用已安装版本的证书；尚未使用证书时自动选择唯一可用身份，没有有效身份时使用 ad-hoc 签名。已使用的证书不可用或有多个待选身份时停止构建。调试构建使用 `CONFIGURATION=Debug ./src/build.sh`。

在 Xcode 中打开 `src/Xclip.xcodeproj`，选择 `Xclip` scheme 可查看和调试源码。完整应用以 `src/build.sh` 输出为准；该脚本还负责同步源码引用、打包 helper 和验签。构建目录、输出目录及签名身份可分别通过 `XCLIP_DERIVED_DIR`、`XCLIP_OUTPUT_DIR`、`XCLIP_CODE_SIGN_IDENTITY` 配置，对应的 `CCLIP_*` 旧变量继续兼容。

## 验证与发布

```bash
./scripts/test.sh
./scripts/test-native-language.sh
./scripts/test-editing-commands.sh
./scripts/package-release.sh
```

`test.sh --network` 可增加本机回环收发测试；菜单栏专项与隔离 QA 包的使用方法见[开发指南](../docs/BUILDING.md)。当前测试位于根目录 `tests/` 和由应用内部入口执行的 `src/OneClip/*Tests.swift`。

`package-release.sh` 无需参数，读取已构建的 `src/dist/Xclip.app` 版本，将发布 DMG、ZIP 和 `SHA256SUMS` 输出到仓库根目录 `dist/`。0.4.0 发布包使用稳定的本地开发证书，未经过 Developer ID 签名和 Apple 公证；安装包生成不改变签名状态，详见[发布指南](../docs/RELEASE.md)。

## 目录与数据兼容

```text
src/
├── OneClip/           # 当前应用源码与内部测试入口，保留兼容目录名
├── RecordingWebPHelper/ # WebP 动图编码 helper 源码
├── Resources/Formula/ # 随包分发的离线公式渲染资源
├── Xclip.xcodeproj/   # Xcode 工程，scheme 为 Xclip
├── build.sh           # 完整应用构建脚本
└── dist/              # 默认生成 Xclip.app，不提交版本控制
```

应用沿用 `local.cclip.app` 标识及 `~/Library/Application Support/CClip` 默认数据目录，继续读取原有历史与设置。不要在开发测试中直接操作日常历史；可使用 `./scripts/make-qa-app.sh` 创建独立标识与数据目录的 QA 应用。

临时签名重新构建后可能需要为当前应用重新授予屏幕录制权限。对已有图片执行 OCR 不需要屏幕录制权限，自动粘贴等功能需要辅助功能权限，具体处理步骤见开发指南。

## 许可

[MIT 许可证](../LICENSE) · [版权声明](../NOTICE.md)
