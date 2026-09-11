#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${XCLIP_PACKAGE_APP:-$REPO_DIR/src/dist/Xclip.app}"
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
codesign --verify --deep --strict --all-architectures "$APP"
lipo "$APP/Contents/MacOS/Xclip" -verify_arch arm64 x86_64
lipo "$APP/Contents/Helpers/CClipScriptRunner" -verify_arch arm64 x86_64
lipo "$APP/Contents/Helpers/XclipWebP" -verify_arch arm64 x86_64
for REQUIRED_RESOURCE in Formula/index.html Formula/katex.min.js Formula/katex.min.css Formula/fonts/KaTeX_Main-Regular.woff2 Formula/LICENSE Licenses/LICENSE-libwebp.txt Licenses/PATENTS-libwebp.txt; do
  if [[ ! -s "$APP/Contents/Resources/$REQUIRED_RESOURCE" ]]; then
    printf 'Missing release resource: %s\n' "$REQUIRED_RESOURCE" >&2
    exit 1
  fi
done
SIGNING_DETAIL="$(codesign -d --verbose=2 "$APP" 2>&1)"
if [[ "$SIGNING_DETAIL" == *'Signature=adhoc'* ]]; then
  SIGNING_ZH='本包使用 ad-hoc 签名。'
  SIGNING_EN='This package uses ad-hoc signing.'
else
  SIGNING_ZH='本包保留构建时使用的代码签名证书。'
  SIGNING_EN='This package retains the code-signing certificate used by the build.'
fi
mkdir -p "$OUTPUT_DIR" "$REPO_DIR/.build"
PACKAGE_STAGE="$(mktemp -d "$REPO_DIR/.build/package.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
ditto --norsrc "$APP" "$PACKAGE_STAGE/Xclip.app"
ln -s /Applications "$PACKAGE_STAGE/Applications"
cp "$REPO_DIR/LICENSE" "$REPO_DIR/NOTICE.md" "$PACKAGE_STAGE/"
cat > "$PACKAGE_STAGE/INSTALL.txt" <<INSTALL
Xclip — macOS 14+ — Apple Silicon / Intel

安装：完全退出旧版 Xclip，将 Xclip.app 拖入 Applications（应用程序），再打开新版本。
语言：设置 → 通用 → 界面语言，选择简体中文或 English。
$SIGNING_ZH 打包不会重新签名或执行 Apple 公证；具体分发身份见 Release 说明。
如系统阻止启动，请查看「系统设置 → 隐私与安全性」中的应用打开提示。
截图需要屏幕录制权限；处理已有图片的 OCR 不需要该权限。
自动粘贴等功能需要辅助功能权限。更新签名后可能需要为当前应用重新授权。
应用沿用原有 CClip 数据目录，替换应用不会删除历史。

Install: Quit the previous Xclip, drag Xclip.app into Applications, then launch the new version.
Language: Settings → General → Interface language → 简体中文 / English.
$SIGNING_EN Packaging does not re-sign or notarize the app; see the release notes for its distribution identity.
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
