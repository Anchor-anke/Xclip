#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$REPO_DIR/.build/tests"
mkdir -p "$TEST_DIR" "$REPO_DIR/.build/ModuleCache"
cd "$REPO_DIR"
TEST_APP="$(mktemp -d "$TEST_DIR/capture-interaction.XXXXXX")/Xclip-Capture-Interaction.app"
trap 'rm -rf "$TEST_APP"' EXIT
mkdir -p "$TEST_APP/Contents/MacOS"
TEST_IDENTIFIER="local.cclip.capture-interaction.$(uuidgen)"
cat > "$TEST_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$TEST_IDENTIFIER</string>
<key>CFBundleExecutable</key><string>CaptureInteractionTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$REPO_DIR/.build/ModuleCache" \
  src/OneClip/AppLanguage.swift src/OneClip/CaptureTools.swift src/OneClip/ImageEditorView.swift \
  src/OneClip/CaptureAnnotation.swift src/OneClip/CaptureAnnotationOverlay.swift src/OneClip/CaptureAnnotationOptions.swift src/OneClip/CaptureRecognitionService.swift src/OneClip/CaptureRedaction.swift src/OneClip/CaptureSelectionOptions.swift src/OneClip/CaptureOutput.swift \
  tests/CaptureAnnotationInteractionTests.swift -o "$TEST_APP/Contents/MacOS/CaptureInteractionTests"
codesign --force --sign - "$TEST_APP"
"$TEST_APP/Contents/MacOS/CaptureInteractionTests" "$TEST_DIR/annotation-interaction.png"
