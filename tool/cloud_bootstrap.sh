#!/usr/bin/env bash
# One-click cloud workspace bootstrap for TallyIsle (帐屿).
# Usage: bash tool/cloud_bootstrap.sh [--with-android]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/env.sh"

mkdir -p "$TALLYISLE_TOOLCHAIN" "$PUB_CACHE" "$GRADLE_USER_HOME/init.d" "$ANDROID_USER_HOME" "$XDG_CONFIG_HOME" "$ANALYZER_STATE_LOCATION_OVERRIDE"

# 1. Seed Gradle init script
if [[ -d "$PROJECT_DIR/tool/seeds/gradle-init" ]]; then
  cp -f "$PROJECT_DIR/tool/seeds/gradle-init/"* "$GRADLE_USER_HOME/init.d/" 2>/dev/null || true
fi

# 2. Ensure JDK 17 is available
if [[ ! -x "$JAVA_HOME/bin/java" ]]; then
  echo "==> Downloading OpenJDK 17 into $TALLYISLE_TOOLCHAIN/jdk-17 ..."
  mkdir -p "$TALLYISLE_TOOLCHAIN/jdk-17"
  JDK_TAR="/tmp/openjdk17.tar.gz"
  curl -fL --retry 3 -o "$JDK_TAR" \
    "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.13%2B11/OpenJDK17U-jdk_x64_linux_hotspot_17.0.13_11.tar.gz"
  tar -xzf "$JDK_TAR" -C "$TALLYISLE_TOOLCHAIN/jdk-17" --strip-components=1
  rm -f "$JDK_TAR"
  export JAVA_HOME="$TALLYISLE_TOOLCHAIN/jdk-17"
  export PATH="$JAVA_HOME/bin:$PATH"
fi

# 3. Bootstrap Flutter 3.47.7
echo "==> Bootstrapping Flutter 3.47.7 ..."
bash "$SCRIPT_DIR/bootstrap_flutter.sh"

# 4. Resolve Dart/Flutter packages & seed native sqlite3 hooks
echo "==> Running flutter pub get ..."
cd "$PROJECT_DIR"
flutter pub get
source "$SCRIPT_DIR/env.sh"

# 5. Optional Android SDK + NDK r28c bootstrap (for APK builds)
if [[ "${1:-}" == "--with-android" ]]; then
  echo "==> Bootstrapping Android SDK 36 + NDK r28c ..."
  if [[ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]]; then
    mkdir -p "$ANDROID_HOME/cmdline-tools"
    CMDLINE_ZIP="/tmp/commandlinetools-linux.zip"
    curl -fL --retry 3 -o "$CMDLINE_ZIP" \
      "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
    unzip -qn "$CMDLINE_ZIP" -d "$ANDROID_HOME/cmdline-tools"
    mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
    rm -f "$CMDLINE_ZIP"
  fi
  bash "$SCRIPT_DIR/bootstrap_android.sh"
  env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_HOME" 'cmake;3.22.1' 'platform-tools'
fi

echo "==> Verifying analyzer and test suite ..."
flutter analyze --no-pub lib test
bash "$SCRIPT_DIR/test.sh"
echo "==> Cloud workspace bootstrap complete!"
