#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_DIR/src/dist/Xclip.app"
OUTPUT_DIR="$REPO_DIR/dist"
if [[ ! -x "$APP/Contents/MacOS/Xclip" ]]; then
  printf 'Build the current application first: ./src/build.sh\n' >&2
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Expected a numeric major.minor.patch application version.\n' >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
lipo "$APP/Contents/MacOS/Xclip" -verify_arch arm64 x86_64
lipo "$APP/Contents/Helpers/CClipScriptRunner" -verify_arch arm64 x86_64
mkdir -p "$OUTPUT_DIR" "$REPO_DIR/.build"
PACKAGE_STAGE="$(mktemp -d "$REPO_DIR/.build/package.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
ditto --norsrc "$APP" "$PACKAGE_STAGE/Xclip.app"
ln -s /Applications "$PACKAGE_STAGE/Applications"
cp "$REPO_DIR/LICENSE" "$REPO_DIR/NOTICE.md" "$PACKAGE_STAGE/"
cat > "$PACKAGE_STAGE/INSTALL.txt" <<'INSTALL'
Xclip — macOS 14+ — Apple Silicon / Intel

安装：完全退出旧版 Xclip，将 Xclip.app 拖入 Applications（应用程序），再打开新版本。
语言：设置 → 通用 → 界面语言，选择简体中文或 English。
本包使用本地 ad-hoc 签名，未经过 Apple Developer ID 签名或公证。
如系统阻止启动，请查看「系统设置 → 隐私与安全性」中的应用打开提示。
截图需要屏幕录制权限；处理已有图片的 OCR 不需要该权限。
自动粘贴等功能需要辅助功能权限。更新签名后可能需要为当前应用重新授权。
应用沿用原有 CClip 数据目录，替换应用不会删除历史。

Install: Quit the previous Xclip, drag Xclip.app into Applications, then launch the new version.
Language: Settings → General → Interface language → 简体中文 / English.
This package is ad-hoc signed, without Apple Developer ID signing or notarization.
If macOS blocks launch, review the app-opening notice in System Settings → Privacy & Security.
Screen recording permission is required for screenshots, but not OCR on existing images.
Automatic paste requires Accessibility. Updated signatures may require permission renewal.
The existing CClip data location is retained; replacing the app does not delete history.

Source and releases: https://github.com/Anchor-anke/Xclip
INSTALL
DMG="Xclip-v${VERSION}-macOS-universal.dmg"
ZIP="Xclip-v${VERSION}-macOS-universal.zip"
hdiutil create -volname "Xclip $VERSION" -srcfolder "$PACKAGE_STAGE" -format UDZO -ov "$OUTPUT_DIR/$DMG"
hdiutil verify "$OUTPUT_DIR/$DMG"
ditto -c -k --norsrc --keepParent "$APP" "$OUTPUT_DIR/$ZIP"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG" "$ZIP" > SHA256SUMS
)
printf 'Release assets: %s\n' "$OUTPUT_DIR"
