#!/usr/bin/env bash
# Isolated toolchain paths for HarmonyOS NEXT / OpenHarmony development under <workspace>/toolchain-ohos.
# Strictly isolated from <workspace>/toolchain so parallel branches never share caches or locks.
TALLYISLE_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TALLYISLE_WORKSPACE="$(cd "$TALLYISLE_PROJECT/.." && pwd)"
TALLYISLE_OHOS_TOOLCHAIN="${TALLYISLE_OHOS_TOOLCHAIN_ROOT:-$TALLYISLE_WORKSPACE/toolchain-ohos}"

export FLUTTER_ROOT="${TALLYISLE_OHOS_FLUTTER_SDK:-$TALLYISLE_OHOS_TOOLCHAIN/flutter-ohos-3.47.7}"
if [[ -d "${TALLYISLE_OHOS_JAVA_SDK:-$TALLYISLE_OHOS_TOOLCHAIN/jdk-17}" ]]; then
  export JAVA_HOME="${TALLYISLE_OHOS_JAVA_SDK:-$TALLYISLE_OHOS_TOOLCHAIN/jdk-17}"
elif [[ -d "/usr/lib/jvm/java-17-openjdk-amd64" ]]; then
  export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
elif [[ -d "/usr/lib/jvm/java-17-openjdk-arm64" ]]; then
  export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-arm64"
fi

export PUB_CACHE="${TALLYISLE_OHOS_PUB_CACHE:-$TALLYISLE_OHOS_TOOLCHAIN/pub-cache}"
export HOS_SDK_HOME="${HOS_SDK_HOME:-$TALLYISLE_OHOS_TOOLCHAIN/hmos-sdk-stub}"
export XDG_CONFIG_HOME="${TALLYISLE_OHOS_CONFIG_HOME:-$TALLYISLE_OHOS_TOOLCHAIN/config}"
export ANALYZER_STATE_LOCATION_OVERRIDE="${TALLYISLE_OHOS_DART_SERVER:-$TALLYISLE_OHOS_TOOLCHAIN/dartServer}"
export CI=true
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
export PATH="$FLUTTER_ROOT/bin:${JAVA_HOME:+$JAVA_HOME/bin:}$PATH"

# Auto-seed pre-verified host sqlite3 native libraries for local unit tests from toolchain-ohos.
if [[ -d "$TALLYISLE_OHOS_TOOLCHAIN/sqlite-lib/hooks-shared" ]]; then
  mkdir -p "$TALLYISLE_PROJECT/.dart_tool/hooks_runner/shared/sqlite3/build"
  cp -rn "$TALLYISLE_OHOS_TOOLCHAIN/sqlite-lib/hooks-shared/"* "$TALLYISLE_PROJECT/.dart_tool/hooks_runner/shared/sqlite3/build/" 2>/dev/null || true
fi
