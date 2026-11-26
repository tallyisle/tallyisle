#!/usr/bin/env bash
# Ad-hoc sign and package TallyIsle.app into:
#   - TallyIsle-macOS-portable.zip
#   - TallyIsle-macOS.dmg
#   - TallyIsle-macOS.pkg
#
# Usage:
#   bash tool/packaging/macos/package_macos.sh \
#     [--app-path build/macos/Build/Products/Release/TallyIsle.app] \
#     [--out-dir .]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PUBSPEC="$REPO_ROOT/pubspec.yaml"

APP_PATH="$REPO_ROOT/build/macos/Build/Products/Release/TallyIsle.app"
OUT_DIR="$REPO_ROOT"

usage() {
  cat <<EOF
Usage: bash tool/packaging/macos/package_macos.sh [options]
  --app-path <path>    Path to built TallyIsle.app (default: build/macos/Build/Products/Release/TallyIsle.app)
  --out-dir <dir>      Output directory for installers (default: repo root)
  --help               Show this message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      APP_PATH="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$PUBSPEC" ]]; then
  echo "error: pubspec.yaml not found at $PUBSPEC" >&2
  exit 1
fi

PUBSPEC_VERSION="$(sed -n 's/^version:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$PUBSPEC" | head -n1 | tr -d '\r')"
if [[ -z "$PUBSPEC_VERSION" || "$PUBSPEC_VERSION" != *+* ]]; then
  echo "error: failed to parse version: X.Y.Z+BUILD from $PUBSPEC (got '$PUBSPEC_VERSION')" >&2
  exit 1
fi

APP_VERSION="${PUBSPEC_VERSION%%+*}"
BUILD_NUMBER="${PUBSPEC_VERSION##*+}"

if ! [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: invalid semantic version '$APP_VERSION'" >&2
  exit 1
fi
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "error: invalid build number '$BUILD_NUMBER'" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: macOS app bundle not found at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

assert_nonempty() {
  local path="$1"
  if [[ ! -s "$path" ]]; then
    echo "error: expected non-empty artifact '$path'" >&2
    exit 1
  fi
  ls -lh "$path"
}

echo "Packaging TallyIsle ${APP_VERSION}+${BUILD_NUMBER} (macOS)"
echo "  app : $APP_PATH"
echo "  out : $OUT_DIR"

ENTITLEMENTS="$REPO_ROOT/macos/Runner/Release.entitlements"
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "error: macOS release entitlements not found at $ENTITLEMENTS" >&2
  exit 1
fi

# Ad-hoc sign nested dylibs & frameworks first (inside-out), then sign the app
# bundle explicitly with Release.entitlements so sandbox + bookmark entitlements
# are never stripped.
if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' dylib; do
    codesign --force --sign - "$dylib"
  done < <(find "$APP_PATH/Contents/Frameworks" -type f -name '*.dylib' -print0)
  while IFS= read -r -d '' fw; do
    codesign --force --sign - "$fw"
  done < <(find "$APP_PATH/Contents/Frameworks" -type d -name '*.framework' -print0)
fi
codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP_PATH"

# 1. Portable ZIP
ZIP_OUT="$OUT_DIR/TallyIsle-macOS-portable.zip"
rm -f "$ZIP_OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_OUT"
assert_nonempty "$ZIP_OUT"

# 2. Compressed UDZO DMG with /Applications drag-install symlink
DMG_OUT="$OUT_DIR/TallyIsle-macOS.dmg"
STAGE="$WORK_DIR/dmg-stage"
mkdir -p "$STAGE"
ditto "$APP_PATH" "$STAGE/TallyIsle.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_OUT"
hdiutil create \
  -volname "TallyIsle" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG_OUT"
assert_nonempty "$DMG_OUT"

# 3. Standard macOS Installer PKG
PKG_OUT="$OUT_DIR/TallyIsle-macOS.pkg"
rm -f "$PKG_OUT"
pkgbuild \
  --component "$APP_PATH" \
  --install-location /Applications \
  --identifier com.tallyisle.app \
  --version "$APP_VERSION" \
  "$PKG_OUT"
assert_nonempty "$PKG_OUT"

echo "macOS packaging completed successfully."
