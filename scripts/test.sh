#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$REPO_DIR/.build/tests"
mkdir -p "$TEST_DIR" "$REPO_DIR/.build/ModuleCache"
cd "$REPO_DIR"
python3 "$REPO_DIR/tests/test_signing_identity.py"
"$REPO_DIR/scripts/test-install-local.sh"
SWIFT=(xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$REPO_DIR/.build/ModuleCache" src/OneClip/AppLanguage.swift)
"${SWIFT[@]}" src/OneClip/StoragePaths.swift src/OneClip/ClipboardItem.swift src/OneClip/HistoryArchive.swift src/OneClip/ClipboardStore.swift tests/StorageTests.swift -o "$TEST_DIR/storage-tests"
"$TEST_DIR/storage-tests"
"${SWIFT[@]}" src/OneClip/CaptureTools.swift src/OneClip/ImageEditorView.swift src/OneClip/CaptureAnnotation.swift src/OneClip/CaptureAnnotationOverlay.swift src/OneClip/CaptureAnnotationOptions.swift src/OneClip/CaptureRecognitionService.swift src/OneClip/CaptureRedaction.swift src/OneClip/CaptureSelectionOptions.swift src/OneClip/CaptureOutput.swift tests/CaptureTests.swift -o "$TEST_DIR/capture-tests"
"$TEST_DIR/capture-tests"
"$REPO_DIR/scripts/test-capture-annotation.sh"
"$REPO_DIR/scripts/test-image-editing-rendering.sh"
"$REPO_DIR/scripts/test-capture-interaction.sh"
"$REPO_DIR/scripts/test-screenshot-session.sh"
"$REPO_DIR/scripts/test-shortcut-settings.sh"
"$REPO_DIR/scripts/test-capture-complete.sh"
"${SWIFT[@]}" -D CCLIP_SCRIPT_HELPER src/OneClip/AutomationServices.swift -o "$TEST_DIR/CClipScriptRunner" -framework Foundation -framework JavaScriptCore -framework Security -framework Combine
"${SWIFT[@]}" -D CCLIP_AUTOMATION_TESTS src/OneClip/AutomationServices.swift src/OneClip/LANSyncService.swift src/OneClip/ClipboardItem.swift src/OneClip/StoragePaths.swift tests/AutomationTests.swift -o "$TEST_DIR/automation-tests"
if [[ $# -gt 0 ]]; then
  "$TEST_DIR/automation-tests" "$TEST_DIR/CClipScriptRunner" "$@"
else
  "$TEST_DIR/automation-tests" "$TEST_DIR/CClipScriptRunner"
fi
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
trap 'rm -rf "$SMOKE_APP"' EXIT
ditto "${APP%/Contents/MacOS/*}" "$SMOKE_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.cclip.smoke.$(uuidgen)" "$SMOKE_APP/Contents/Info.plist"
codesign --force --sign - "$SMOKE_APP"
CCLIP_DATA_DIR="$SMOKE_DIR/data" "$SMOKE_APP/Contents/MacOS/Xclip" --smoke-test
printf 'All tests finished. Smoke data: %s\n' "$SMOKE_DIR"
