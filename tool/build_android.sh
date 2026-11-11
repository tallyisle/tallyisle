#!/usr/bin/env bash
# Builds both the arm64 Debug APK (release/帐屿-开发版.apk) and the slim arm64
# Release APK (release/帐屿-正式版.apk), signed with the same debug.keystore so
# Android devices can seamlessly overwrite-install between the two profiles.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$TALLYISLE_PROJECT"

# On ARM64 Linux hosts, Google's Flutter engine cache ships x86_64 host
# gen_snapshot binaries under android-*-{release,profile}/linux-x64/. Ensure a
# user-space qemu-x86_64 wrapper exists at linux-arm64/gen_snapshot.
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
  QEMU_ROOT="$TALLYISLE_TOOLCHAIN/qemu-x86_64"
  if [[ ! -x "$QEMU_ROOT/usr/bin/qemu-x86_64" ]]; then
    tmp_dl="$(mktemp -d)"
    (
      cd "$tmp_dl"
      apt-get download qemu-user libc6-amd64-cross
      mkdir -p "$QEMU_ROOT"
      for deb in *.deb; do
        dpkg-deb -x "$deb" "$QEMU_ROOT"
      done
    )
    rm -rf "$tmp_dl"
  fi
  for mode_dir in android-arm64-release android-arm64-profile android-arm-release android-arm-profile android-x64-release android-x64-profile; do
    eng_dir="$FLUTTER_ROOT/bin/cache/artifacts/engine/$mode_dir"
    if [[ -x "$eng_dir/linux-x64/gen_snapshot" && ! -x "$eng_dir/linux-arm64/gen_snapshot" ]]; then
      mkdir -p "$eng_dir/linux-arm64"
      cat > "$eng_dir/linux-arm64/gen_snapshot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_DIR="$(cd "$SCRIPT_DIR/../../../../../../.." && pwd)"
exec "$TOOLCHAIN_DIR/qemu-x86_64/usr/bin/qemu-x86_64" \
  -L "$TOOLCHAIN_DIR/qemu-x86_64/usr/x86_64-linux-gnu" \
  "$SCRIPT_DIR/../linux-x64/gen_snapshot" "$@"
EOF
      chmod +x "$eng_dir/linux-arm64/gen_snapshot"
    fi
  done
fi

mkdir -p "$TALLYISLE_PROJECT/release"

flutter pub get --enforce-lockfile --offline

echo "==> [1/2] Building Debug APK (release/帐屿-开发版.apk) ..."
flutter build apk --debug --no-pub --target-platform android-arm64 "$@"
cp "$TALLYISLE_PROJECT/build/app/outputs/flutter-apk/app-debug.apk" \
  "$TALLYISLE_PROJECT/release/帐屿-开发版.apk"

echo "==> [2/2] Building Slim Release APK (release/帐屿-正式版.apk) ..."
flutter build apk --release --no-pub --target-platform android-arm64 --tree-shake-icons "$@"
cp "$TALLYISLE_PROJECT/build/app/outputs/flutter-apk/app-release.apk" \
  "$TALLYISLE_PROJECT/release/帐屿-正式版.apk"

# Refresh plugin registrant for local test/debug runs without touching pubspec.lock.
flutter pub get --enforce-lockfile --offline >/dev/null

ls -lh "$TALLYISLE_PROJECT/release/帐屿-开发版.apk" "$TALLYISLE_PROJECT/release/帐屿-正式版.apk"
sha256sum "$TALLYISLE_PROJECT/release/帐屿-开发版.apk" "$TALLYISLE_PROJECT/release/帐屿-正式版.apk"
