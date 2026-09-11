#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$REPO_DIR/.build/tests"
mkdir -p "$TEST_DIR" "$REPO_DIR/.build/ModuleCache"
cd "$REPO_DIR"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$REPO_DIR/.build/ModuleCache" \
  src/OneClip/ScreenshotSession.swift tests/ScreenshotSessionTests.swift \
  -o "$TEST_DIR/screenshot-session-tests"
"$TEST_DIR/screenshot-session-tests"
