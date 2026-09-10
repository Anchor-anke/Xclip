#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$REPO_DIR/.build/tests"
mkdir -p "$TEST_DIR" "$REPO_DIR/.build/ModuleCache"
cd "$REPO_DIR"
SWIFT=(xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$REPO_DIR/.build/ModuleCache" src/OneClip/AppLanguage.swift)
"${SWIFT[@]}" src/OneClip/StoragePaths.swift src/OneClip/ClipboardItem.swift src/OneClip/HistoryArchive.swift src/OneClip/ClipboardStore.swift tests/StorageTests.swift -o "$TEST_DIR/storage-tests"
"$TEST_DIR/storage-tests"
"${SWIFT[@]}" src/OneClip/CaptureTools.swift src/OneClip/ImageEditorView.swift tests/CaptureTests.swift -o "$TEST_DIR/capture-tests"
"$TEST_DIR/capture-tests"
"${SWIFT[@]}" -D CCLIP_SCRIPT_HELPER src/OneClip/AutomationServices.swift -o "$TEST_DIR/CClipScriptRunner" -framework Foundation -framework JavaScriptCore -framework Security -framework Combine
"${SWIFT[@]}" -D CCLIP_AUTOMATION_TESTS src/OneClip/AutomationServices.swift src/OneClip/LANSyncService.swift src/OneClip/ClipboardItem.swift src/OneClip/StoragePaths.swift tests/AutomationTests.swift -o "$TEST_DIR/automation-tests"
"$TEST_DIR/automation-tests" "$TEST_DIR/CClipScriptRunner" "${@}"
if [[ -f tests/SharingTests.swift ]]; then
  "${SWIFT[@]}" -D CCLIP_SHARING_TESTS src/OneClip/SharingExtensions.swift src/OneClip/AutomationServices.swift src/OneClip/StoragePaths.swift tests/SharingTests.swift -o "$TEST_DIR/sharing-tests"
  "$TEST_DIR/sharing-tests"
fi
# Compile the production lock class verbatim; the fixture never creates its singleton or accesses Keychain.
python3 - "$REPO_DIR" "$TEST_DIR/PrivacyLockProduction.swift" <<'PY'
import pathlib, sys
source = (pathlib.Path(sys.argv[1]) / "src/OneClip/WorkflowState.swift").read_text()
start = source.index("class PrivacyLock: ObservableObject")
end = source.index("/// Typed local URL", start)
imports = "import Foundation\nimport Combine\nimport LocalAuthentication\nimport Security\nimport CryptoKit\n"
pathlib.Path(sys.argv[2]).write_text(imports + source[start:end])
PY
"${SWIFT[@]}" -D PRIVACY_LOCK_STANDALONE_TESTS "$TEST_DIR/PrivacyLockProduction.swift" tests/PrivacyLockTests.swift -o "$TEST_DIR/privacy-tests"
"$TEST_DIR/privacy-tests"
APP="${XCLIP_TEST_APP:-$REPO_DIR/src/dist/Xclip.app/Contents/MacOS/Xclip}"
if [[ ! -x "$APP" ]]; then
  printf 'Build the application first using ./src/build.sh\n' >&2
  exit 1
fi
SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cclip-smoke.XXXXXX")"
# Isolate the preferences domain as well as the database. The ordinary app's
# language and settings must not be changed by synthetic smoke fixtures.
SMOKE_APP="$SMOKE_DIR/Xclip-Smoke.app"
ditto "${APP%/Contents/MacOS/*}" "$SMOKE_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.cclip.smoke.$(uuidgen)" "$SMOKE_APP/Contents/Info.plist"
codesign --force --sign - "$SMOKE_APP"
CCLIP_DATA_DIR="$SMOKE_DIR/data" "$SMOKE_APP/Contents/MacOS/Xclip" --smoke-test
printf 'All tests finished. Smoke data: %s\n' "$SMOKE_DIR"
