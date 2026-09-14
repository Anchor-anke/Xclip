#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$REPO_DIR/.build/tests/drag-cancellation"
mkdir -p "$TEST_DIR" "$REPO_DIR/.build/ModuleCache"
xcrun swiftc -swift-version 5 -D DRAG_CANCELLATION_TESTS -parse-as-library -module-cache-path "$REPO_DIR/.build/ModuleCache" \
  "$REPO_DIR/src/OneClip/DragCancellation.swift" "$REPO_DIR/src/OneClip/DragSystemEventObserver.swift" \
  "$REPO_DIR/tests/DragCancellationTests.swift" \
  -o "$TEST_DIR/drag-cancellation-tests"
if [[ "${1:-}" == "--native" ]]; then
  "$TEST_DIR/drag-cancellation-tests" --queue
  xcrun swiftc -swift-version 5 -D DRAG_CANCELLATION_TESTS -parse-as-library -module-cache-path "$REPO_DIR/.build/ModuleCache" \
    "$REPO_DIR/src/OneClip/DragCancellation.swift" "$REPO_DIR/src/OneClip/DragSystemEventObserver.swift" \
    "$REPO_DIR/tests/DragCancellationNativeTests.swift" \
    -o "$TEST_DIR/drag-cancellation-native-tests"
  "$TEST_DIR/drag-cancellation-native-tests"
  "$TEST_DIR/drag-cancellation-native-tests" --hidden-source
  "$TEST_DIR/drag-cancellation-native-tests" --observed-mouse
  "$TEST_DIR/drag-cancellation-native-tests" --observed-mouse --hidden-source
else
  "$TEST_DIR/drag-cancellation-tests" "$@"
fi
