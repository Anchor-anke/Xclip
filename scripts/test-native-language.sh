#!/bin/bash
# Synthetic NSMenus plus a separate windowless AppKit event-tracking probe.
# Neither process displays menus, invokes menu actions or accesses the pasteboard.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO_DIR/.build/tests" "$REPO_DIR/.build/ModuleCache"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$REPO_DIR/.build/ModuleCache" \
  "$REPO_DIR/src/OneClip/AppLanguage.swift" \
  "$REPO_DIR/src/OneClip/NativeLanguageController.swift" \
  "$REPO_DIR/tests/NativeLanguageTests.swift" \
  -framework AppKit -framework Combine -o "$REPO_DIR/.build/tests/native-language-tests"
"$REPO_DIR/.build/tests/native-language-tests"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$REPO_DIR/.build/ModuleCache" \
  "$REPO_DIR/src/OneClip/AppLanguage.swift" \
  "$REPO_DIR/src/OneClip/NativeLanguageController.swift" \
  "$REPO_DIR/tests/NativeLanguageEventTests.swift" \
  -framework AppKit -framework Combine -o "$REPO_DIR/.build/tests/native-language-event-tests"
"$REPO_DIR/.build/tests/native-language-event-tests"
