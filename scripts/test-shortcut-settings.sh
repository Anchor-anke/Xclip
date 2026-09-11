#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$REPO_DIR/.build/tests/shortcut-settings"
mkdir -p "$TEST_DIR" "$REPO_DIR/.build/ModuleCache"
cd "$REPO_DIR"
# Compile the production models, shortcut service and recorder verbatim. Tests use
# value helpers and an inactive pause/resume lifecycle; they never register hotkeys or open UI.
python3 - "$REPO_DIR" "$TEST_DIR/ShortcutSettingsProduction.swift" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1]) / "src/OneClip"
workflow = (root / "WorkflowState.swift").read_text()
desktop = (root / "DesktopServices.swift").read_text()
preferences = (root / "PreferencesView.swift").read_text()
production = "import Foundation\nimport AppKit\nimport SwiftUI\nimport Combine\nimport Carbon\n"
production += workflow[workflow.index("func L("):workflow.index("class WorkflowState:")]
production += desktop[desktop.index("class GlobalShortcuts:"):desktop.index("class DesktopEvents")]
production += preferences[preferences.index("func shortcutTitle("):preferences.index("func openAccessibility()")]
production += preferences[preferences.index("class ShortcutRecorder:"):preferences.index("class WorkspaceBackup")]
production += """
// Dependency sentinels ensure pure tests cannot touch live workflow or paste state.
class WorkflowState {
    static var shared: WorkflowState { fatalError("Live workflow must not be accessed") }
    var document = WorkflowDocument()
}
class PasteCoordinator {
    static var shared: PasteCoordinator { fatalError("Paste must not be accessed") }
    func captureTarget() { fatalError("Desktop focus must not be accessed") }
    func paste(_ item: ClipboardItem) { fatalError("Clipboard must not be accessed") }
}
"""
pathlib.Path(sys.argv[2]).write_text(production)
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$REPO_DIR/.build/ModuleCache" \
  src/OneClip/AppLanguage.swift src/OneClip/ClipboardItem.swift \
  "$TEST_DIR/ShortcutSettingsProduction.swift" tests/ShortcutSettingsTests.swift \
  -o "$TEST_DIR/shortcut-settings-tests"
"$TEST_DIR/shortcut-settings-tests"
