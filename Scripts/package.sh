#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
DIST_DIR="$ROOT_DIR/dist"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_NAME="MaosDevOps.app"
APP_DIR="$DIST_DIR/$APP_NAME"
EXECUTABLE="$APP_DIR/Contents/MacOS/MaosDevOps"

cd "$ROOT_DIR"
rm -rf "$DERIVED_DATA" "$DIST_DIR"
mkdir -p "$DIST_DIR"

plutil -lint MaosDevops/Resources/Info.plist MaosDevops/Resources/MaosDevops.entitlements

xcodebuild \
  -project MaosDevops.xcodeproj \
  -scheme MaosDevOps \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS,arch=x86_64' \
  ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=YES \
  MACOSX_DEPLOYMENT_TARGET=10.15 \
  CODE_SIGNING_ALLOWED=NO \
  clean build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME"
test -d "$BUILT_APP"
ditto "$BUILT_APP" "$APP_DIR"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"

test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_DIR/Contents/Info.plist")" = "10.15"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")" = "$APP_VERSION"
test -x "$EXECUTABLE"
test -f "$APP_DIR/Contents/Resources/AppIcon.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_DIR/Contents/Info.plist")" = "AppIcon"

ARCHS_FOUND="$(lipo -archs "$EXECUTABLE")"
if [[ "$ARCHS_FOUND" != "x86_64" ]]; then
  echo "Expected an Intel-only x86_64 executable, found: $ARCHS_FOUND" >&2
  exit 1
fi

MIN_OS="$(otool -l "$EXECUTABLE" | awk '
  /LC_BUILD_VERSION/ { in_build = 1; next }
  in_build && $1 == "minos" { print $2; exit }
  /LC_VERSION_MIN_MACOSX/ { in_legacy = 1; next }
  in_legacy && $1 == "version" { print $2; exit }
')"
if [[ "$MIN_OS" != "10.15" ]]; then
  echo "Expected Mach-O minimum macOS 10.15, found: ${MIN_OS:-unknown}" >&2
  exit 1
fi

# Ad-hoc signing makes the public bundle internally consistent. A Developer ID
# identity can replace this later without changing the packaging flow.
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

if [[ "${RUN_LAUNCH_SMOKE_TEST:-0}" == "1" ]]; then
  echo "Launching MaosDevOps.app via LaunchServices to verify startup"
  smoke_status_file="/tmp/maosdevops-launch-smoke.status"
  smoke_stage_log="/tmp/maosdevops-launch-smoke.status.log"
  rm -f "$smoke_status_file" "$smoke_stage_log"

  # Prefer the .app bundle path (same as a user double-click). Direct MacOS/binary
  # launches can skip LaunchServices activation and hide AppKit lifecycle bugs.
  open -n "$APP_DIR" --args --launch-smoke-test

  smoke_ok=""
  for attempt in {1..40}; do
    if [[ -f "$smoke_status_file" ]]; then
      if grep -q 'success=1' "$smoke_status_file"; then
        smoke_ok=1
      else
        smoke_ok=0
      fi
      break
    fi
    # App may have exited before writing — treat as failure once process is gone
    # and the marker is still missing after a few seconds.
    if ! pgrep -x MaosDevOps >/dev/null 2>&1 && [[ $attempt -gt 6 ]]; then
      smoke_ok=0
      break
    fi
    sleep 0.5
  done

  echo "----- launch smoke stage log -----"
  if [[ -f "$smoke_stage_log" ]]; then
    cat "$smoke_stage_log"
  else
    echo "(no stage log written — app may not have reached AppDelegate)"
  fi
  echo "----- launch smoke status -----"
  if [[ -f "$smoke_status_file" ]]; then
    cat "$smoke_status_file"
  else
    echo "(missing status file)"
  fi

  pkill -x MaosDevOps 2>/dev/null || true
  sleep 0.5

  if [[ -z "$smoke_ok" ]]; then
    echo "error: Launch smoke test timed out after 20 seconds (no status marker)" >&2
    exit 1
  fi
  if [[ "$smoke_ok" != "1" ]]; then
    while IFS= read -r line; do
      echo "error: launch smoke: $line"
    done < <(cat "$smoke_stage_log" 2>/dev/null; cat "$smoke_status_file" 2>/dev/null)
    echo "error: Launch smoke test failed" >&2
    exit 1
  fi
  echo "Launch smoke test passed"
fi

ditto -c -k --sequesterRsrc --keepParent \
  "$APP_DIR" "$DIST_DIR/MaosDevOps-macOS-10.15-Intel.zip"

DMG_ROOT="$ROOT_DIR/.build/dmg-root"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
ditto "$APP_DIR" "$DMG_ROOT/$APP_NAME"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
  -volname "MaosDevOps" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DIST_DIR/MaosDevOps-macOS-10.15-Intel.dmg"

cd "$DIST_DIR"
shasum -a 256 \
  MaosDevOps-macOS-10.15-Intel.zip \
  MaosDevOps-macOS-10.15-Intel.dmg > SHA256SUMS.txt

echo "Packaged MaosDevOps $APP_VERSION ($BUILD_NUMBER) for macOS 10.15 x86_64"
