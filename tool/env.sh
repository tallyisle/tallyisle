#!/usr/bin/env bash
# Self-contained toolchain paths under /home/debian/Coding/toolchain.
TALLYISLE_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TALLYISLE_TOOLCHAIN="${TALLYISLE_TOOLCHAIN_ROOT:-/home/debian/Coding/toolchain}"
export FLUTTER_ROOT="${TALLYISLE_FLUTTER_SDK:-$TALLYISLE_TOOLCHAIN/flutter-3.47.7}"
export JAVA_HOME="${TALLYISLE_JAVA_SDK:-$TALLYISLE_TOOLCHAIN/jdk-17}"
export ANDROID_HOME="${TALLYISLE_ANDROID_SDK:-$TALLYISLE_TOOLCHAIN/android-sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PUB_CACHE="${TALLYISLE_PUB_CACHE:-$TALLYISLE_TOOLCHAIN/pub-cache}"
export GRADLE_USER_HOME="${TALLYISLE_GRADLE_HOME:-$TALLYISLE_TOOLCHAIN/gradle}"
export ANDROID_USER_HOME="${TALLYISLE_ANDROID_USER:-$TALLYISLE_TOOLCHAIN/android-user}"
export XDG_CONFIG_HOME="${TALLYISLE_CONFIG_HOME:-$TALLYISLE_TOOLCHAIN/config}"
export CI=true
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
export PATH="$FLUTTER_ROOT/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
export ANALYZER_STATE_LOCATION_OVERRIDE="${TALLYISLE_DART_SERVER:-$TALLYISLE_TOOLCHAIN/dartServer}"

# Auto-seed pre-verified sqlite3 native libraries so flutter test / build apk work offline even after flutter clean.
if [[ -d "$TALLYISLE_TOOLCHAIN/sqlite-lib/hooks-shared" ]]; then
  mkdir -p "$TALLYISLE_PROJECT/.dart_tool/hooks_runner/shared/sqlite3/build"
  cp -rn "$TALLYISLE_TOOLCHAIN/sqlite-lib/hooks-shared/"* "$TALLYISLE_PROJECT/.dart_tool/hooks_runner/shared/sqlite3/build/" 2>/dev/null || true
fi
