#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$REPO_DIR/.build/tests/overwrite-installer"
mkdir -p "$TEST_DIR" "$REPO_DIR/.build/ModuleCache"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$REPO_DIR/.build/ModuleCache" \
  "$REPO_DIR/src/Installer/OverwriteInstaller.swift" "$REPO_DIR/tests/OverwriteInstallerTests.swift" \
  -o "$TEST_DIR/overwrite-installer-tests"
"$TEST_DIR/overwrite-installer-tests"
