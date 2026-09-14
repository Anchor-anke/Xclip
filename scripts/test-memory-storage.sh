#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
mkdir -p .build/tests .build/ModuleCache
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/ModuleCache \
  src/OneClip/AppLanguage.swift src/OneClip/StoragePaths.swift src/OneClip/ClipboardItem.swift \
  src/OneClip/HistoryArchive.swift src/OneClip/ClipboardStore.swift tests/MemoryStorageTests.swift \
  -o .build/tests/memory-storage-tests
.build/tests/memory-storage-tests
