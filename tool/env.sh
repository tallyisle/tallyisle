#!/usr/bin/env bash
# No global SDK/config edits. Override these task-specific paths when needed.
TALLYISLE_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FLUTTER_ROOT="${TALLYISLE_FLUTTER_SDK:-/home/debian/Coding/toolchain/flutter-3.47.7}"
export JAVA_HOME="${TALLYISLE_JAVA_SDK:-/home/debian/Coding/toolchain/jdk-17}"
export ANDROID_HOME="${TALLYISLE_ANDROID_SDK:-$TALLYISLE_PROJECT/.toolchain/android-sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PUB_CACHE="$TALLYISLE_PROJECT/.toolchain/pub-cache"
export GRADLE_USER_HOME="$TALLYISLE_PROJECT/.toolchain/gradle"
export ANDROID_USER_HOME="$TALLYISLE_PROJECT/.toolchain/android-user"
export XDG_CONFIG_HOME="$TALLYISLE_PROJECT/.toolchain/config"
export CI=true
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
export PATH="$FLUTTER_ROOT/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
export ANALYZER_STATE_LOCATION_OVERRIDE="$TALLYISLE_PROJECT/.toolchain/dartServer"
