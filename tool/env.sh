#!/usr/bin/env bash
# Self-contained toolchain paths under <workspace>/toolchain.
TALLYISLE_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TALLYISLE_WORKSPACE="$(cd "$TALLYISLE_PROJECT/.." && pwd)"
TALLYISLE_TOOLCHAIN="${TALLYISLE_TOOLCHAIN_ROOT:-$TALLYISLE_WORKSPACE/toolchain}"
export FLUTTER_ROOT="${TALLYISLE_FLUTTER_SDK:-$TALLYISLE_TOOLCHAIN/flutter-3.47.7}"
if [[ -d "${TALLYISLE_JAVA_SDK:-$TALLYISLE_TOOLCHAIN/jdk-17}" ]]; then
  export JAVA_HOME="${TALLYISLE_JAVA_SDK:-$TALLYISLE_TOOLCHAIN/jdk-17}"
elif [[ -d "/usr/lib/jvm/java-17-openjdk-amd64" ]]; then
  export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
elif [[ -d "/usr/lib/jvm/java-17-openjdk-arm64" ]]; then
  export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-arm64"
else
  export JAVA_HOME="${TALLYISLE_JAVA_SDK:-$TALLYISLE_TOOLCHAIN/jdk-17}"
fi
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

# Auto-seed pre-verified sqlite3 native libraries, debug keystore, and Gradle init scripts from tool/seeds or toolchain.
if [[ -d "$TALLYISLE_PROJECT/tool/seeds/sqlite-hooks" ]]; then
  mkdir -p "$TALLYISLE_PROJECT/.dart_tool/hooks_runner/shared/sqlite3/build"
  cp -rn "$TALLYISLE_PROJECT/tool/seeds/sqlite-hooks/"* "$TALLYISLE_PROJECT/.dart_tool/hooks_runner/shared/sqlite3/build/" 2>/dev/null || true
elif [[ -d "$TALLYISLE_TOOLCHAIN/sqlite-lib/hooks-shared" ]]; then
  mkdir -p "$TALLYISLE_PROJECT/.dart_tool/hooks_runner/shared/sqlite3/build"
  cp -rn "$TALLYISLE_TOOLCHAIN/sqlite-lib/hooks-shared/"* "$TALLYISLE_PROJECT/.dart_tool/hooks_runner/shared/sqlite3/build/" 2>/dev/null || true
fi

if [[ -f "$TALLYISLE_PROJECT/tool/seeds/android-user/debug.keystore" && ! -f "$ANDROID_USER_HOME/debug.keystore" ]]; then
  mkdir -p "$ANDROID_USER_HOME"
  cp -n "$TALLYISLE_PROJECT/tool/seeds/android-user/debug.keystore" "$ANDROID_USER_HOME/debug.keystore" 2>/dev/null || true
fi

if [[ -d "$TALLYISLE_PROJECT/tool/seeds/android-licenses" ]]; then
  mkdir -p "$ANDROID_HOME/licenses"
  cp -rn "$TALLYISLE_PROJECT/tool/seeds/android-licenses/"* "$ANDROID_HOME/licenses/" 2>/dev/null || true
fi

