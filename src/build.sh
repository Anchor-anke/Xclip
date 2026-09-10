#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$PROJECT_DIR")"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DIR="${XCLIP_DERIVED_DIR:-${CCLIP_DERIVED_DIR:-$REPO_DIR/.build/DerivedData}}"
OUTPUT_DIR="${XCLIP_OUTPUT_DIR:-${CCLIP_OUTPUT_DIR:-$PROJECT_DIR/dist}}"
CODE_SIGN_IDENTITY="${XCLIP_CODE_SIGN_IDENTITY:-${CCLIP_CODE_SIGN_IDENTITY:--}}"
mkdir -p "$OUTPUT_DIR" "$REPO_DIR/.build/ModuleCache"
python3 "$REPO_DIR/scripts/update-project.py"
xcodebuild -quiet -project "$PROJECT_DIR/Xclip.xcodeproj" -scheme Xclip -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED_DIR" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" build
SOURCE_APP="$DERIVED_DIR/Build/Products/$CONFIGURATION/Xclip.app"
mkdir -p "$SOURCE_APP/Contents/Helpers"
for CCLIP_ARCH in arm64 x86_64; do
  swiftc -parse-as-library -swift-version 5 -target "$CCLIP_ARCH-apple-macosx14.0" -module-cache-path "$REPO_DIR/.build/ModuleCache" -D CCLIP_SCRIPT_HELPER "$PROJECT_DIR/OneClip/AppLanguage.swift" "$PROJECT_DIR/OneClip/AutomationServices.swift" -o "$REPO_DIR/.build/CClipScriptRunner-$CCLIP_ARCH" -framework Foundation -framework JavaScriptCore -framework Security -framework Combine
done
lipo -create "$REPO_DIR/.build/CClipScriptRunner-arm64" "$REPO_DIR/.build/CClipScriptRunner-x86_64" -output "$SOURCE_APP/Contents/Helpers/CClipScriptRunner"
cp "$REPO_DIR/LICENSE" "$REPO_DIR/NOTICE.md" "$SOURCE_APP/Contents/Resources/"
# Use the same selected identity for nested code and the app. A signing failure is
# fatal under set -e; never silently replace a requested certificate with ad-hoc signing.
codesign --force --sign "$CODE_SIGN_IDENTITY" "$SOURCE_APP/Contents/Helpers/CClipScriptRunner"
codesign --force --sign "$CODE_SIGN_IDENTITY" "$SOURCE_APP"
# Replace only our generated app: merging a prior Debug bundle leaves unsigned preview dylibs behind.
if [[ -e "$OUTPUT_DIR/Xclip.app" ]]; then rm -rf "$OUTPUT_DIR/Xclip.app"; fi
ditto "$SOURCE_APP" "$OUTPUT_DIR/Xclip.app"
codesign --verify --deep --strict "$OUTPUT_DIR/Xclip.app"
printf 'Built %s\n' "$OUTPUT_DIR/Xclip.app"
if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
  printf '\n警告：本次使用临时（ad-hoc）签名，更新构建后屏幕录制等系统授权可能失效。\n' >&2
  printf '若已授权仍无法截图，请完全退出 Xclip（关闭窗口不等于退出），在系统设置中移除旧授权项，再重新添加并授权当前应用：\n  %s\n' "$OUTPUT_DIR/Xclip.app" >&2
  printf '授权后重新打开该应用；持续开发建议用 XCLIP_CODE_SIGN_IDENTITY 指定已有的稳定代码签名证书。\n' >&2
fi
