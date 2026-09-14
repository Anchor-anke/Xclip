#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${XCLIP_PACKAGE_APP:-$REPO_DIR/src/dist/Xclip.app}"
OUTPUT_DIR="${XCLIP_PACKAGE_OUTPUT_DIR:-$REPO_DIR/dist}"
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
mkdir -p "$OUTPUT_DIR" "$REPO_DIR/.build"
PACKAGE_STAGE="$(mktemp -d "$REPO_DIR/.build/package.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
ditto --norsrc "$APP" "$PACKAGE_STAGE/Xclip.app"
"$REPO_DIR/scripts/build-overwrite-installer.sh" "$PACKAGE_STAGE/Xclip.app" "$PACKAGE_STAGE/安装 Xclip.app"
ln -s /Applications "$PACKAGE_STAGE/Applications"
cp "$REPO_DIR/LICENSE" "$REPO_DIR/NOTICE.md" "$PACKAGE_STAGE/"
cat > "$PACKAGE_STAGE/INSTALL.txt" <<INSTALL
Xclip — macOS 14+ — Apple Silicon / Intel

安装或更新：双击「安装 Xclip.app」，选择原来的安装位置，再点击安装。
安装器会请求该位置的旧版正常退出，覆盖安装后重新打开；无需先删除旧版。
如果旧版未能正常退出，安装会停止，请处理正在进行的工作后重试。
安装器与 Xclip.app 必须保留在同一目录；ZIP 请先完整解压，DMG 请先打开。
若未能自动找到新版，点击「选择新版应用…」并选择安装包内的 Xclip.app。
只更新所选位置，不会自动清理其他目录的应用副本，也不会在线下载更新。
也可完全退出旧版后，将 Xclip.app 拖到原位置并选择「替换」。
语言：设置 → 通用 → 界面语言，选择简体中文或 English。
本包保留 Xclip 的构建签名，安装器复用同一证书。打包不会执行 Apple 公证；具体分发身份见 Release 说明。
如系统阻止启动，请查看「系统设置 → 隐私与安全性」中的应用打开提示。
截图需要屏幕录制权限；处理已有图片的 OCR 不需要该权限。
自动粘贴等功能需要辅助功能权限。更新签名后可能需要为当前应用重新授权。
应用沿用原有 CClip 数据目录及偏好设置，覆盖安装不会删除历史、附件或配置。

Install or update: Open “安装 Xclip.app” (Install Xclip), select the existing installation location, then install.
The installer asks that copy to quit normally, replaces it, then reopens it. No prior deletion is needed.
If the previous app does not quit normally, installation stops; finish any active work and retry.
Keep the installer beside Xclip.app. Extract the entire ZIP first, or open the DMG.
If the new app is not found automatically, click “选择新版应用…” (Choose new app) and select Xclip.app from the package.
Only the selected location is updated. Other app copies are not removed, and no update is downloaded online.
Alternatively, quit the previous app and drag Xclip.app to the same location, choosing Replace.
Language: Settings → General → Interface language → 简体中文 / English.
Xclip retains its build signature; the installer uses the same certificate. Packaging does not notarize either app.
See the release notes for the distribution identity.
If macOS blocks launch, review the app-opening notice in System Settings → Privacy & Security.
Screen recording permission is required for screenshots, but not OCR on existing images.
Automatic paste requires Accessibility. Updated signatures may require permission renewal.
The existing CClip data location and preferences are retained, including history, attachments and configuration.

Source and releases: https://github.com/Anchor-anke/Xclip
INSTALL
DMG="Xclip-v${VERSION}-macOS-universal.dmg"
ZIP="Xclip-v${VERSION}-macOS-universal.zip"
hdiutil create -volname "Xclip $VERSION" -srcfolder "$PACKAGE_STAGE" -format UDZO -ov "$OUTPUT_DIR/$DMG"
hdiutil verify "$OUTPUT_DIR/$DMG"
ditto -c -k --norsrc "$PACKAGE_STAGE" "$OUTPUT_DIR/$ZIP"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG" "$ZIP" > SHA256SUMS
)
printf 'Release assets: %s\n' "$OUTPUT_DIR"
