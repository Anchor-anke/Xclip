#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO_DIR/.build/tests" "$REPO_DIR/.build/ModuleCache"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$REPO_DIR/.build/ModuleCache" \
  "$REPO_DIR/src/OneClip/AppLanguage.swift" \
  "$REPO_DIR/src/OneClip/LocalizedEditingCommands.swift" \
  "$REPO_DIR/tests/LocalizedEditingCommandsTests.swift" \
  -framework AppKit -framework SwiftUI -framework Combine -o "$REPO_DIR/.build/tests/editing-commands-tests"
"$REPO_DIR/.build/tests/editing-commands-tests"
