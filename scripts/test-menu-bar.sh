#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO_DIR/.build/tests" "$REPO_DIR/.build/ModuleCache"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$REPO_DIR/.build/ModuleCache" \
  "$REPO_DIR/src/OneClip/StoragePaths.swift" "$REPO_DIR/src/OneClip/MenuBarController.swift" \
  "$REPO_DIR/tests/MenuBarTests.swift" -o "$REPO_DIR/.build/tests/menu-bar-tests"
CCLIP_PROBE_DATA="$(mktemp -d "${TMPDIR:-/tmp}/cclip-menu-bar.XXXXXX")"
CCLIP_DATA_DIR="$CCLIP_PROBE_DATA" "$REPO_DIR/.build/tests/menu-bar-tests"
printf 'Menu bar diagnostic report: %s/menu-bar-regression.json\n' "$CCLIP_PROBE_DATA"
