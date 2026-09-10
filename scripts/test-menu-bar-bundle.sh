#!/bin/bash
# LaunchServices integration check, separate from the CLI lifecycle test.
# This builds a temporary, ad-hoc signed test app with no clipboard services.
set -euo pipefail

BUILD_ONLY=false
case "${1:-}" in
  --build-only) BUILD_ONLY=true; shift ;;
  --help|-h)
    printf '%s\n' 'Usage: scripts/test-menu-bar-bundle.sh [--build-only]' \
      'Default: build and launch an isolated .app through LaunchServices.' \
      '--build-only: compile/package/validate signing; do not launch any UI.' \
      'Reports and the temporary test bundle are retained under .build/.'
    exit 0 ;;
esac
if [[ $# -ne 0 ]]; then printf 'Unknown argument: %s\n' "$1" >&2; exit 2; fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO_DIR/.build"
RUN_DIR="$(mktemp -d "$REPO_DIR/.build/menu-bar-bundle.XXXXXX")"
BUNDLE_ID="local.cclip.test.menubar"
PROBE_APP="$RUN_DIR/MenuBarProbe.app"
PROBE_DATA="$RUN_DIR/data"
mkdir -p "$PROBE_APP/Contents/MacOS" "$PROBE_DATA" "$RUN_DIR/ModuleCache"

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$RUN_DIR/ModuleCache" \
  "$REPO_DIR/src/OneClip/StoragePaths.swift" "$REPO_DIR/src/OneClip/MenuBarController.swift" \
  "$REPO_DIR/tests/MenuBarTests.swift" -o "$PROBE_APP/Contents/MacOS/MenuBarProbe"

python3 - "$PROBE_APP" "$PROBE_DATA" "$BUNDLE_ID" <<'PY'
from pathlib import Path
import plistlib, sys
app, data, identifier = sys.argv[1:]
info = {
    "CFBundleIdentifier": identifier, "CFBundleExecutable": "MenuBarProbe",
    "CFBundleName": "Xclip Menu Bar Integration Test", "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "14.0", "NSPrincipalClass": "NSApplication",
    "NSHighResolutionCapable": True, "CClipTestDataDirectory": data,
}
(Path(app) / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$PROBE_APP"
codesign --verify --deep --strict "$PROBE_APP"

# Keep validation runnable against a saved report without launching a GUI.
cat > "$RUN_DIR/validate-report.py" <<'PY'
from pathlib import Path
import json, re, sys

ENABLED_STAGES = ["controller.enable", "controller.restoreRepeated", "controller.policy.accessory",
                  "controller.policy.regular", "controller.restore.afterWindowHidden",
                  "controller.reenable", "controller.hide.productionFilter"]

def rectangle(value):
    if not isinstance(value, str):
        return None
    numbers = re.findall(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?", value)
    if len(numbers) != 4:
        return None
    result = tuple(float(number) for number in numbers)
    return result if result[2] > 0 and result[3] > 0 else None

def intersects(first, second):
    if first is None or second is None:
        return False
    x, y, width, height = first
    other_x, other_y, other_width, other_height = second
    return x < other_x + other_width and other_x < x + width and y < other_y + other_height and other_y < y + height

def visible_window(window):
    return (window.get("visible") is True and window.get("occlusionVisible") is True
            and window.get("intersectsScreen") is True
            and isinstance(window.get("alpha"), (int, float)) and window["alpha"] > 0)

def display_evidence(sample):
    # NSStatusItem has per-display windows. button.window is only one of them.
    # Ignore removed items' retained windows, even when their occlusion bit is stale.
    windows = sample.get("ownWindows", [])
    if not isinstance(windows, list):
        windows = []
    current = [window for window in windows if isinstance(window, dict)
               and window.get("level") == 25 and window.get("visible") is True]
    screens = sample.get("screenFrames", [])
    if not isinstance(screens, list):
        screens = []
    per_screen = []
    for index, frame in enumerate(screens):
        matches = [window for window in current if intersects(rectangle(window.get("frame")), rectangle(frame))]
        per_screen.append({"screenIndex": index, "screenFrame": frame, "currentStatusWindows": matches,
                           "hasVisibleStatusWindow": any(visible_window(window) for window in matches)})
    return {"stage": sample.get("stage"), "buttonWindow": sample.get("statusWindow"),
            "currentStatusWindows": current, "screens": per_screen,
            "anyScreenVisible": any(screen["hasVisibleStatusWindow"] for screen in per_screen),
            "allScreensVisible": bool(per_screen) and all(screen["hasVisibleStatusWindow"] for screen in per_screen)}

def validate(report, expected_id, expected_app):
    failures = []
    def require(condition, message):
        if not condition:
            failures.append(message)
    expected_app = str(Path(expected_app).resolve())
    require(report.get("bundleIdentifier") == expected_id, "Foundation bundle identifier differs from the isolated test app")
    require(report.get("runningApplicationBundleID") == expected_id, "Running application bundle identifier differs from the isolated test app")
    for key in ("bundlePath", "runningApplicationBundleURL"):
        require(report.get(key) == expected_app, f"{key} differs from the launched test bundle")
    executable = expected_app + "/Contents/MacOS/MenuBarProbe"
    for key in ("executablePath", "runningApplicationExecutableURL"):
        require(report.get(key) == executable, f"{key} differs from the isolated test executable")
    require(report.get("dataDirectory") == str(Path(expected_app).parent / "data"), "Probe did not use its isolated data directory")
    require(isinstance(report.get("checks"), int) and report["checks"] >= 36, "Lifecycle suite did not finish its expected checks")
    require(report.get("failures") == [], "Lifecycle suite reported failures: " + str(report.get("failures")))
    samples = report.get("samples", [])
    require(isinstance(samples, list), "Samples must be a list")
    if not isinstance(samples, list):
        samples = []
    stages = {sample.get("stage"): sample for sample in samples if isinstance(sample, dict)}
    require(len(stages) == len(samples), "Duplicate or malformed stage samples")
    for stage in ENABLED_STAGES:
        sample = stages.get(stage, {})
        require(bool(sample), f"Missing integration sample: {stage}")
        require(sample.get("itemVisible") is True and sample.get("imageExists") is True,
                f"{stage}: item/image was not configured")
        evidence = display_evidence(sample)
        # isVisible alone passes for the Tahoe placeholder. At least one current
        # status window must also have occlusion and actual screen intersection.
        require(evidence["anyScreenVisible"], f"{stage}: no current status window has visibility evidence on any screen")
    require("controller.disable.final" in stages, "The final cleanup sample is missing")
    return failures

def main():
    report_path, expected_id, expected_app = sys.argv[1:]
    path = Path(report_path)
    try:
        report = json.loads(path.read_text())
        if not isinstance(report, dict):
            raise ValueError("Report must be a JSON object")
        failures = validate(report, expected_id, expected_app)
        displays = [display_evidence(sample) for sample in report.get("samples", [])
                    if isinstance(sample, dict) and sample.get("stage") in ENABLED_STAGES]
    except (OSError, ValueError, TypeError, KeyError) as error:
        failures = ["Could not validate completed bundle report: " + str(error)]
        displays = []
    all_screens = bool(displays) and all(stage["allScreensVisible"] for stage in displays)
    limitations = [f"{stage['stage']}: no visibility evidence on screen {screen['screenIndex']} ({screen['screenFrame']})"
                   for stage in displays for screen in stage["screens"] if not screen["hasVisibleStatusWindow"]]
    summary = {"passed": not failures, "failures": failures, "responsibleApplicationVerified": False,
               "allScreensHaveVisibilityEvidence": all_screens, "displayResults": displays, "limitations": limitations,
               "scope": "LaunchServices bundle identity, lifecycle, and visibility evidence on at least one display per enabled stage; no screenshot or all-display visual acceptance"}
    path.with_name("bundle-validation.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("MenuBarBundle: " + ("PASS" if not failures else "FAIL"))
    for failure in failures:
        print("  " + failure)
    if not all_screens:
        print("Visibility is not confirmed on every screen; see per-screen results and limitations in bundle-validation.json.")
    print("The standalone CLI lifecycle result cannot replace this bundle check.")
    print("Own-window geometry does not prove that the user can see the icon.")
    print("NSRunningApplication bundle identity does not verify ControlCenter's responsible-app grouping.")
    return 1 if failures else 0

if __name__ == "__main__":
    raise SystemExit(main())
PY
printf 'Test bundle: %s\nReport directory: %s\n' "$PROBE_APP" "$RUN_DIR"
if $BUILD_ONLY; then
  printf 'Build-only completed. No application was launched.\n'
  exit 0
fi

# open performs the LaunchServices path under test. The fixture exits by itself
# after ~12 seconds and has a 40-second watchdog; never target a normal CClip app.
python3 - "$PROBE_APP" "$RUN_DIR" <<'PY'
from pathlib import Path
import json, subprocess, sys
app, run_dir = sys.argv[1:]
folder = Path(run_dir)
command = ["/usr/bin/open", "-n", "-W", "--env", "CCLIP_DATA_DIR=" + str(folder / "data"),
           "--stdout", str(folder / "stdout.log"),
           "--stderr", str(folder / "stderr.log"), app]
try:
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=50)
    status = {"method": "LaunchServices via open", "exitCode": result.returncode, "output": result.stdout}
except subprocess.TimeoutExpired:
    status = {"method": "LaunchServices via open", "exitCode": 124, "output": "LaunchServices wait timed out; the test fixture has its own watchdog."}
(folder / "launcher.json").write_text(json.dumps(status, indent=2) + "\n")
if status["exitCode"]:
    print(status["output"], file=sys.stderr)
    raise SystemExit(status["exitCode"])
PY
python3 "$RUN_DIR/validate-report.py" "$PROBE_DATA/menu-bar-regression.json" "$BUNDLE_ID" "$PROBE_APP"
