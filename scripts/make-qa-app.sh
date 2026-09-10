#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA_APP="$REPO_DIR/.build/Xclip-QA.app"
QA_DATA="$REPO_DIR/.build/qa-data"
mkdir -p "$QA_DATA"
if [[ -e "$QA_APP" ]]; then rm -rf "$QA_APP"; fi
ditto "$REPO_DIR/src/dist/Xclip.app" "$QA_APP"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.cclip.qa' "$QA_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Xclip QA' "$QA_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Xclip QA' "$QA_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CClipTestDataDirectory" "$QA_APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CClipTestDataDirectory string $QA_DATA" "$QA_APP/Contents/Info.plist"
codesign --force --sign - "$QA_APP"
codesign --verify --deep --strict "$QA_APP"
printf 'QA application: %s\nData: %s\n' "$QA_APP" "$QA_DATA"
