#!/usr/bin/env bash
# Builds the arm64 development APK.
# Gradle fails on the case-insensitive /mnt/d path (it lower-cases the project
# path), so the build runs in an ext4 mirror and the APK is copied back.
set -euo pipefail
source "$(dirname "$0")/env.sh"
SRC="$TALLYISLE_PROJECT"
MIRROR="${TALLYISLE_BUILD_MIRROR:-/home/debian/Coding/tallyisle-build}"
mkdir -p "$MIRROR"
# Fresh copy of sources (keeps the mirror's Gradle/build caches).
rm -rf "$MIRROR/lib" "$MIRROR/test" "$MIRROR/assets"
tar -C "$SRC" \
  --exclude=./archive --exclude=./build --exclude=./.dart_tool --exclude=./.git \
  --exclude=./.toolchain --exclude=./android/.gradle --exclude=./android/local.properties \
  -cf - . | tar -C "$MIRROR" -xf -
ln -sfn "$SRC/.toolchain" "$MIRROR/.toolchain"
cd "$MIRROR"
flutter pub get --enforce-lockfile --offline
flutter build apk --debug --no-pub --target-platform android-arm64 "$@"
mkdir -p "$SRC/build/app/outputs/flutter-apk"
cp build/app/outputs/flutter-apk/app-debug.apk "$SRC/build/app/outputs/flutter-apk/app-debug.apk"
sha256sum "$SRC/build/app/outputs/flutter-apk/app-debug.apk"
