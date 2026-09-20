#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
mkdir -p .build/tests .build/ModuleCache
SWIFT=(xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/ModuleCache src/OneClip/AppLanguage.swift)
CAPTURE=(src/OneClip/CaptureTools.swift src/OneClip/CaptureDesktopSnapshot.swift src/OneClip/ImageEditorView.swift src/OneClip/SessionTemporaryFiles.swift src/OneClip/CaptureAnnotation.swift
  src/OneClip/CaptureAnnotationOverlay.swift src/OneClip/CaptureAnnotationOptions.swift
  src/OneClip/CaptureSelectionOptions.swift src/OneClip/CaptureOutput.swift
  src/OneClip/CaptureRecognitionService.swift src/OneClip/CaptureRedaction.swift)
"${SWIFT[@]}" "${CAPTURE[@]}" tests/AdvancedAnnotationTests.swift -o .build/tests/advanced-annotation-tests
.build/tests/advanced-annotation-tests
"${SWIFT[@]}" -D DRAG_CANCELLATION_TESTS "${CAPTURE[@]}" src/OneClip/DragCancellation.swift src/OneClip/DragSystemEventObserver.swift src/OneClip/PinnedImageController.swift tests/PinnedImageTests.swift -o .build/tests/pinned-image-tests
.build/tests/pinned-image-tests "$REPO_DIR/.build/tests/pinned-image.png"
"${SWIFT[@]}" "${CAPTURE[@]}" src/OneClip/CaptureScrolling.swift tests/CaptureScrollingTests.swift -o .build/tests/capture-scrolling-tests
.build/tests/capture-scrolling-tests
scripts/build-recording-webp.sh
"${SWIFT[@]}" src/OneClip/CaptureRecording.swift tests/CaptureRecordingTests.swift -o .build/tests/capture-recording-tests
.build/tests/capture-recording-tests "$REPO_DIR/.build/recording-webp/XclipWebP"
scripts/test-capture-workflow.sh
