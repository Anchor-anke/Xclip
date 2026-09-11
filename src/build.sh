#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$PROJECT_DIR")"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DIR="${XCLIP_DERIVED_DIR:-${CCLIP_DERIVED_DIR:-$REPO_DIR/.build/DerivedData}}"
OUTPUT_DIR="${XCLIP_OUTPUT_DIR:-${CCLIP_OUTPUT_DIR:-$PROJECT_DIR/dist}}"
BUILD_METHOD="${XCLIP_BUILD_METHOD:-direct}"
INSTALL="${XCLIP_INSTALL:-1}"
case "$BUILD_METHOD" in direct|xcode) ;; *) printf 'XCLIP_BUILD_METHOD must be direct or xcode.\n' >&2; exit 1 ;; esac
case "$INSTALL" in 0|1) ;; *) printf 'XCLIP_INSTALL must be 0 or 1.\n' >&2; exit 1 ;; esac
CUSTOM_OUTPUT=0
if [[ -n "${XCLIP_OUTPUT_DIR:-${CCLIP_OUTPUT_DIR:-}}" ]]; then CUSTOM_OUTPUT=1; fi
# Inspect the installed certificate before building; never create certificates or
# silently downgrade a certificate-signed installation to an ad-hoc signature.
CODE_SIGN_IDENTITY="$(python3 "$REPO_DIR/scripts/select-signing-identity.py" --installed-app "$OUTPUT_DIR/Xclip.app")"
mkdir -p "$REPO_DIR/.build/ModuleCache"
BUILD_STAGE="$(mktemp -d "$REPO_DIR/.build/build.XXXXXX")"
SOURCE_APP="$BUILD_STAGE/Xclip.app"
BUILD_COMPLETE=0
INSTALL_DONE=0
finish() {
  local result=$?
  if [[ "$BUILD_COMPLETE" == 1 && "$INSTALL_DONE" == 0 ]]; then
    if [[ -d "$SOURCE_APP" ]]; then
      printf '已签名构建保留在：%s\n' "$SOURCE_APP"
    else
      printf '安装或旧副本清理未完整结束，请查看上方的安装结果与实际应用路径。\n' >&2
    fi
  else
    rm -rf "$BUILD_STAGE"
  fi
  return "$result"
}
trap finish EXIT
python3 "$REPO_DIR/scripts/update-project.py"
# Read the active project's actual configuration without starting Xcode's build
# service. Quote shell values with shlex and expand only known plist variables.
python3 - "$PROJECT_DIR" "$BUILD_STAGE" "$CONFIGURATION" <<'PY'
import json, pathlib, plistlib, re, shlex, subprocess, sys
project, stage = map(pathlib.Path, sys.argv[1:3])
configuration = sys.argv[3]
pbx = json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(project / 'Xclip.xcodeproj/project.pbxproj')]))
objects = pbx['objects']
root = objects[pbx['rootObject']]
target = next(item for item in objects.values() if item.get('isa') == 'PBXNativeTarget' and item.get('name') == 'Xclip')
def settings(owner):
    configs = objects[owner['buildConfigurationList']]['buildConfigurations']
    return next(objects[item]['buildSettings'] for item in configs if objects[item]['name'] == configuration)
values = {'TARGET_NAME': 'Xclip', **settings(root), **settings(target)}
pattern = re.compile(r'\$\(([^)]+)\)|\$\{([^}]+)\}')
def expand(value):
    if isinstance(value, str):
        for _ in range(10):
            if not pattern.search(value):
                return value
            value = pattern.sub(lambda match: str(values[match[1] or match[2]]), value)
        raise ValueError('Recursive build setting: ' + value)
    if isinstance(value, dict):
        return {key: expand(item) for key, item in value.items()}
    if isinstance(value, list):
        return [expand(item) for item in value]
    return value
values['EXECUTABLE_NAME'] = expand(values['PRODUCT_NAME'])
if values['EXECUTABLE_NAME'] != 'Xclip':
    raise ValueError('The local installer requires the Xclip executable name.')
info = expand(plistlib.loads((project / values['INFOPLIST_FILE']).read_bytes()))
info['CFBundleDevelopmentRegion'] = root.get('developmentRegion', 'en')
info['CFBundleSupportedPlatforms'] = ['MacOSX']
(stage / 'Info.plist').write_bytes(plistlib.dumps(info))
exports = {
    'DEPLOYMENT_TARGET': values['MACOSX_DEPLOYMENT_TARGET'],
    'SWIFT_VERSION': str(values['SWIFT_VERSION']).split('.')[0],
    'APP_ICON': values['ASSETCATALOG_COMPILER_APPICON_NAME'],
    'ACCENT_COLOR': values['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'],
    'APP_ENTITLEMENTS': str(project / values['CODE_SIGN_ENTITLEMENTS']),
}
(stage / 'settings.sh').write_text(''.join(f'{key}={shlex.quote(str(value))}\n' for key, value in exports.items()))
PY
source "$BUILD_STAGE/settings.sh"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SWIFT_FLAGS=(-O -whole-module-optimization)
if [[ "$CONFIGURATION" == Debug ]]; then SWIFT_FLAGS=(-Onone -g -D DEBUG); fi
if [[ "$BUILD_METHOD" == xcode ]]; then
  xcodebuild -quiet -project "$PROJECT_DIR/Xclip.xcodeproj" -scheme Xclip -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED_DIR" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" build
  ditto "$DERIVED_DIR/Build/Products/$CONFIGURATION/Xclip.app" "$SOURCE_APP"
else
  mkdir -p "$SOURCE_APP/Contents/MacOS" "$SOURCE_APP/Contents/Resources"
  xcrun actool --compile "$SOURCE_APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target "$DEPLOYMENT_TARGET" --app-icon "$APP_ICON" --accent-color "$ACCENT_COLOR" \
    --output-partial-info-plist "$BUILD_STAGE/Assets.plist" --output-format human-readable-text --warnings --errors \
    "$PROJECT_DIR/OneClip/Assets.xcassets" "$PROJECT_DIR/OneClip/Preview Content/Preview Assets.xcassets"
  python3 - "$BUILD_STAGE" "$SOURCE_APP" <<'PY'
import pathlib, plistlib, sys
stage, app = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads((stage / 'Info.plist').read_bytes())
info.update(plistlib.loads((stage / 'Assets.plist').read_bytes()))
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(app / 'Contents/PkgInfo').write_bytes(b'APPL????')
PY
  for language in "$PROJECT_DIR/OneClip/"*.lproj; do
    ditto "$language" "$SOURCE_APP/Contents/Resources/$(basename "$language")"
  done
fi
mkdir -p "$SOURCE_APP/Contents/Helpers"
compile_architecture() {
  local arch="$1"
  if [[ "$BUILD_METHOD" == direct ]]; then
    xcrun swiftc -parse-as-library -swift-version "$SWIFT_VERSION" -sdk "$SDK_PATH" \
      -target "$arch-apple-macosx$DEPLOYMENT_TARGET" -module-cache-path "$REPO_DIR/.build/ModuleCache" \
      -module-name Xclip "${SWIFT_FLAGS[@]}" "$PROJECT_DIR/OneClip/"*.swift -o "$BUILD_STAGE/Xclip-$arch"
  fi
  xcrun swiftc -parse-as-library -swift-version "$SWIFT_VERSION" -sdk "$SDK_PATH" \
    -target "$arch-apple-macosx$DEPLOYMENT_TARGET" -module-cache-path "$REPO_DIR/.build/ModuleCache" \
    -D CCLIP_SCRIPT_HELPER "$PROJECT_DIR/OneClip/AppLanguage.swift" "$PROJECT_DIR/OneClip/AutomationServices.swift" \
    -o "$BUILD_STAGE/CClipScriptRunner-$arch" -framework Foundation -framework JavaScriptCore -framework Security -framework Combine
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
if [[ "$BUILD_METHOD" == direct ]]; then
  lipo -create "$BUILD_STAGE/Xclip-arm64" "$BUILD_STAGE/Xclip-x86_64" -output "$SOURCE_APP/Contents/MacOS/Xclip"
fi
lipo -create "$BUILD_STAGE/CClipScriptRunner-arm64" "$BUILD_STAGE/CClipScriptRunner-x86_64" -output "$SOURCE_APP/Contents/Helpers/CClipScriptRunner"
cp "$REPO_DIR/LICENSE" "$REPO_DIR/NOTICE.md" "$SOURCE_APP/Contents/Resources/"
if [[ -d "$PROJECT_DIR/Resources" ]]; then ditto "$PROJECT_DIR/Resources" "$SOURCE_APP/Contents/Resources"; fi
"$REPO_DIR/scripts/build-recording-webp.sh"
cp "$REPO_DIR/.build/recording-webp/XclipWebP" "$SOURCE_APP/Contents/Helpers/XclipWebP"
mkdir -p "$SOURCE_APP/Contents/Resources/Licenses"
cp "$REPO_DIR/.build/recording-webp/LICENSE-libwebp.txt" "$REPO_DIR/.build/recording-webp/PATENTS-libwebp.txt" "$SOURCE_APP/Contents/Resources/Licenses/"
codesign --force --sign "$CODE_SIGN_IDENTITY" "$SOURCE_APP/Contents/Helpers/XclipWebP"
codesign --force --sign "$CODE_SIGN_IDENTITY" "$SOURCE_APP/Contents/Helpers/CClipScriptRunner"
codesign --force --sign "$CODE_SIGN_IDENTITY" --entitlements "$APP_ENTITLEMENTS" "$SOURCE_APP"
codesign --verify --deep --strict "$SOURCE_APP"
lipo "$SOURCE_APP/Contents/MacOS/Xclip" -verify_arch arm64 x86_64
lipo "$SOURCE_APP/Contents/Helpers/CClipScriptRunner" -verify_arch arm64 x86_64
lipo "$SOURCE_APP/Contents/Helpers/XclipWebP" -verify_arch arm64 x86_64
BUILD_COMPLETE=1
if [[ "$INSTALL" == 0 ]]; then
  printf '仅构建并验签；未替换安装或删除旧副本。\n'
  exit 0
fi
if [[ "$CUSTOM_OUTPUT" == 1 ]]; then
  printf '自定义输出：仅更新指定目录，不清理其他应用副本。\n'
  python3 "$REPO_DIR/scripts/install-local.py" --source "$SOURCE_APP" --destination "$OUTPUT_DIR/Xclip.app" --no-cleanup
else
  python3 "$REPO_DIR/scripts/install-local.py" --source "$SOURCE_APP"
fi
INSTALL_DONE=1
printf 'Built %s\n' "$OUTPUT_DIR/Xclip.app"
