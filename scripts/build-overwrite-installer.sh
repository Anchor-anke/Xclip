#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# != 2 ]]; then
  printf 'Usage: %s /source/Xclip.app /destination/安装\ Xclip.app\n' "$0" >&2
  exit 1
fi
SOURCE_APP="$1"
DESTINATION_APP="$2"
if [[ ! -x "$SOURCE_APP/Contents/MacOS/Xclip" ]]; then
  printf 'Missing source Xclip application: %s\n' "$SOURCE_APP" >&2
  exit 1
fi
if [[ -e "$DESTINATION_APP" || -L "$DESTINATION_APP" ]]; then
  printf 'Installer output already exists; choose an unused output path: %s\n' "$DESTINATION_APP" >&2
  exit 1
fi
if [[ "$DESTINATION_APP" != *.app ]]; then
  printf 'Installer output must end in .app.\n' >&2
  exit 1
fi
codesign --verify --deep --strict --all-architectures "$SOURCE_APP"
lipo "$SOURCE_APP/Contents/MacOS/Xclip" -verify_arch arm64 x86_64
# The installer trusts only its own certificate. Never let a caller's signing
# override change that identity or silently create an unusable ad-hoc package.
SOURCE_IDENTITY="$(python3 - "$REPO_DIR/scripts" "$SOURCE_APP" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location('signing', pathlib.Path(sys.argv[1]) / 'select-signing-identity.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
try:
    identity = signing.installed_certificate(pathlib.Path(sys.argv[2]))
    if not identity:
        raise signing.SigningError('覆盖安装器要求源应用使用稳定证书签名；ad-hoc 应用仍可手动拖放安装。')
    print(identity)
except (OSError, signing.SigningError) as error:
    print(error, file=sys.stderr)
    sys.exit(1)
PY
)"
CODE_SIGN_IDENTITY="$(XCLIP_CODE_SIGN_IDENTITY="$SOURCE_IDENTITY" python3 "$REPO_DIR/scripts/select-signing-identity.py" --installed-app "$SOURCE_APP")"
mkdir -p "$REPO_DIR/.build/ModuleCache"
BUILD_STAGE="$(mktemp -d "$REPO_DIR/.build/installer.XXXXXX")"
trap 'rm -rf "$BUILD_STAGE"' EXIT
INSTALLER_APP="$BUILD_STAGE/安装 Xclip.app"
mkdir -p "$INSTALLER_APP/Contents/MacOS" "$INSTALLER_APP/Contents/Resources"
python3 - "$SOURCE_APP" "$INSTALLER_APP" <<'PY'
import pathlib, plistlib, shutil, sys
source, installer = map(pathlib.Path, sys.argv[1:])
source_info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
if source_info.get('CFBundleIdentifier') != 'local.cclip.app':
    raise SystemExit('The source must be a standard Xclip application (local.cclip.app).')
info = {
    'CFBundleIdentifier': 'local.cclip.installer',
    'CFBundleName': '安装 Xclip',
    'CFBundleDisplayName': '安装 Xclip',
    'CFBundleExecutable': 'XclipInstaller',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': source_info['CFBundleShortVersionString'],
    'CFBundleVersion': source_info['CFBundleVersion'],
    'CFBundleDevelopmentRegion': 'zh_CN',
    'CFBundleSupportedPlatforms': ['MacOSX'],
    'LSMinimumSystemVersion': '14.0',
    'NSHighResolutionCapable': True,
}
icon_name = source_info.get('CFBundleIconFile', '')
if icon_name and pathlib.Path(icon_name).name == icon_name:
    icon_file = icon_name if icon_name.endswith('.icns') else icon_name + '.icns'
    icon = source / 'Contents/Resources' / icon_file
    if icon.is_file():
        shutil.copy2(icon, installer / 'Contents/Resources' / icon_file)
        info['CFBundleIconFile'] = icon_file
(installer / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(installer / 'Contents/PkgInfo').write_bytes(b'APPL????')
PY
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
compile_architecture() {
  local arch="$1"
  xcrun swiftc -parse-as-library -swift-version 5 -sdk "$SDK_PATH" \
    -target "$arch-apple-macosx14.0" -module-cache-path "$REPO_DIR/.build/ModuleCache" \
    -module-name XclipInstaller -O -whole-module-optimization \
    "$REPO_DIR/src/Installer/"*.swift -o "$BUILD_STAGE/XclipInstaller-$arch" \
    -framework AppKit -framework Foundation -framework Security
}
compile_architecture arm64 > "$BUILD_STAGE/arm64.log" 2>&1 &
ARM_PID=$!
compile_architecture x86_64 > "$BUILD_STAGE/x86_64.log" 2>&1 &
INTEL_PID=$!
COMPILE_FAILED=0
wait "$ARM_PID" || COMPILE_FAILED=1
wait "$INTEL_PID" || COMPILE_FAILED=1
cat "$BUILD_STAGE/arm64.log" "$BUILD_STAGE/x86_64.log"
if [[ "$COMPILE_FAILED" == 1 ]]; then exit 1; fi
lipo -create "$BUILD_STAGE/XclipInstaller-arm64" "$BUILD_STAGE/XclipInstaller-x86_64" -output "$INSTALLER_APP/Contents/MacOS/XclipInstaller"
codesign --force --sign "$CODE_SIGN_IDENTITY" "$INSTALLER_APP"
codesign --verify --deep --strict --all-architectures "$INSTALLER_APP"
lipo "$INSTALLER_APP/Contents/MacOS/XclipInstaller" -verify_arch arm64 x86_64
mkdir -p "$(dirname "$DESTINATION_APP")"
ditto --norsrc "$INSTALLER_APP" "$DESTINATION_APP"
codesign --verify --deep --strict --all-architectures "$DESTINATION_APP"
printf 'Built installer: %s\nKeep it next to the signed Xclip.app when distributing.\n' "$DESTINATION_APP"
