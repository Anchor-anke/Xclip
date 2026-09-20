#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$REPO_DIR/.build/tests"
mkdir -p "$TEST_DIR" "$REPO_DIR/.build/ModuleCache"
cd "$REPO_DIR"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$REPO_DIR/.build/ModuleCache" \
  src/OneClip/AppLanguage.swift src/OneClip/CaptureTools.swift src/OneClip/CaptureDesktopSnapshot.swift src/OneClip/ImageEditorView.swift src/OneClip/SessionTemporaryFiles.swift \
  src/OneClip/CaptureAnnotation.swift src/OneClip/CaptureAnnotationOverlay.swift src/OneClip/CaptureAnnotationOptions.swift src/OneClip/CaptureRecognitionService.swift src/OneClip/CaptureRedaction.swift src/OneClip/CaptureSelectionOptions.swift src/OneClip/CaptureOutput.swift \
  tests/ImageEditingRenderingTests.swift -o "$TEST_DIR/image-editing-rendering-tests"
"$TEST_DIR/image-editing-rendering-tests"
