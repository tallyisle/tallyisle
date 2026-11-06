#!/usr/bin/env bash
# Builds the arm64 development APK directly in the project directory (native ext4)
# and copies it to release/帐屿-开发版.apk.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$TALLYISLE_PROJECT"
flutter pub get --enforce-lockfile --offline
flutter build apk --debug --no-pub --target-platform android-arm64 "$@"
mkdir -p "$TALLYISLE_PROJECT/release"
cp "$TALLYISLE_PROJECT/build/app/outputs/flutter-apk/app-debug.apk" "$TALLYISLE_PROJECT/release/帐屿-开发版.apk"
sha256sum "$TALLYISLE_PROJECT/release/帐屿-开发版.apk"
