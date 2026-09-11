#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
mkdir -p .build/tests .build/ModuleCache
TEST_STAGE="$(mktemp -d "$REPO_DIR/.build/tests/workflow.XXXXXX")"
TEST_APP="$TEST_STAGE/CaptureWorkflowTests.app"
trap 'rm -rf "$TEST_STAGE"' EXIT
mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources"
cat > "$TEST_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.cclip.workflow-test.$(uuidgen)</string><key>CFBundleExecutable</key><string>CaptureWorkflowTests</string><key>CFBundlePackageType</key><string>APPL</string><key>LSBackgroundOnly</key><true/></dict></plist>
PLIST
ditto src/Resources/Formula "$TEST_APP/Contents/Resources/Formula"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/ModuleCache \
  src/OneClip/AppLanguage.swift src/OneClip/CaptureTools.swift src/OneClip/ImageEditorView.swift \
  src/OneClip/CaptureAnnotation.swift src/OneClip/CaptureAnnotationOverlay.swift \
  src/OneClip/CaptureAnnotationOptions.swift src/OneClip/CaptureRedaction.swift src/OneClip/CaptureSelectionOptions.swift \
  src/OneClip/CaptureOutput.swift src/OneClip/CaptureRecognitionService.swift src/OneClip/CaptureFormulaPreview.swift \
  tests/CaptureWorkflowTests.swift -o "$TEST_APP/Contents/MacOS/CaptureWorkflowTests"
codesign --force --sign - "$TEST_APP"
"$TEST_APP/Contents/MacOS/CaptureWorkflowTests" "$REPO_DIR/.build/tests/formula-preview.png"
