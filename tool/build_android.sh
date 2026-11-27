#!/usr/bin/env bash
# Builds symmetric Android arm64 and x64 Release APKs in release/, signed
# with the fixed debug.keystore so local and CI builds share the same signing key.
#
# Usage:
#   bash tool/build_android.sh [--arch arm64|x64|all] [extra flutter build flags...]
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$TALLYISLE_PROJECT"

ARCH="all"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      if [[ $# -lt 2 ]]; then
        echo "error: --arch requires a value (arm64|x64|all)" >&2
        exit 2
      fi
      ARCH="$2"
      shift 2
      ;;
    --arch=*)
      ARCH="${1#--arch=}"
      shift
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

case "$ARCH" in
  arm64|x64|all) ;;
  *)
    echo "error: unsupported --arch '$ARCH' (expected arm64, x64, or all)" >&2
    exit 2
    ;;
esac

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

verify_apk_abi() {
  local apk="$1"
  local expected_abi="$2"
  local forbidden_abi="$3"
  local listing
  listing="$(python3 -m zipfile -l "$apk")"
  if ! grep -q "lib/${expected_abi}/" <<< "$listing"; then
    echo "error: $apk is missing expected ABI lib/${expected_abi}/" >&2
    exit 1
  fi
  if grep -q "lib/${forbidden_abi}/" <<< "$listing"; then
    echo "error: $apk unexpectedly contains forbidden ABI lib/${forbidden_abi}/" >&2
    exit 1
  fi
  echo "  ABI OK: $(basename "$apk") (has lib/${expected_abi}/, no lib/${forbidden_abi}/)"
}

BUILT_APKS=()

if [[ "$ARCH" == "arm64" || "$ARCH" == "all" ]]; then
  ARM64_APK="$TALLYISLE_PROJECT/release/TallyIsle-Android-arm64.apk"

  echo "==> Building Android arm64 Release APK (release/TallyIsle-Android-arm64.apk) ..."
  flutter build apk --release --no-pub --target-platform android-arm64 --tree-shake-icons ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
  cp "$TALLYISLE_PROJECT/build/app/outputs/flutter-apk/app-release.apk" "$ARM64_APK"

  BUILT_APKS+=("$ARM64_APK")
fi

if [[ "$ARCH" == "x64" || "$ARCH" == "all" ]]; then
  X64_APK="$TALLYISLE_PROJECT/release/TallyIsle-Android-x64.apk"

  echo "==> Building Android x64 Release APK (release/TallyIsle-Android-x64.apk) ..."
  flutter build apk --release --no-pub --target-platform android-x64 --tree-shake-icons ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
  cp "$TALLYISLE_PROJECT/build/app/outputs/flutter-apk/app-release.apk" "$X64_APK"

  BUILT_APKS+=("$X64_APK")
fi

# Refresh plugin registrant for local test runs without touching pubspec.lock.
flutter pub get --enforce-lockfile --offline >/dev/null

echo "==> Verifying APK ABI isolation ..."
if [[ "$ARCH" == "arm64" || "$ARCH" == "all" ]]; then
  verify_apk_abi "$TALLYISLE_PROJECT/release/TallyIsle-Android-arm64.apk" "arm64-v8a" "x86_64"
fi
if [[ "$ARCH" == "x64" || "$ARCH" == "all" ]]; then
  verify_apk_abi "$TALLYISLE_PROJECT/release/TallyIsle-Android-x64.apk" "x86_64" "arm64-v8a"
fi

ls -lh "${BUILT_APKS[@]}"
sha256sum "${BUILT_APKS[@]}"
