#!/bin/bash
# Explicit opt-in: this regression briefly shows this test process's native windows.
set -euo pipefail
if [[ "${1:-}" != "--show-preparation-ui" ]]; then
    echo 'Usage: scripts/test-recording-presentation.sh --show-preparation-ui' >&2
    echo 'Briefly shows recording preparation windows; never captures the desktop or microphone.' >&2
    exit 2
fi
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
mkdir -p .build/tests .build/ModuleCache
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/ModuleCache \
    src/OneClip/AppLanguage.swift src/OneClip/CaptureRecording.swift tests/CaptureRecordingPresentationTests.swift \
    -o .build/tests/capture-recording-presentation-tests
.build/tests/capture-recording-presentation-tests
