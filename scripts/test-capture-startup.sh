#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$REPO_DIR/.build/tests/capture-startup"
MODULE_CACHE="$REPO_DIR/.build/ModuleCache/capture-startup"
mkdir -p "$TEST_DIR" "$MODULE_CACHE"
cd "$REPO_DIR"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$MODULE_CACHE" \
  src/OneClip/CaptureDesktopSnapshot.swift tests/CaptureDesktopSnapshotTests.swift \
  -o "$TEST_DIR/capture-desktop-snapshot-tests"
"$TEST_DIR/capture-desktop-snapshot-tests"
