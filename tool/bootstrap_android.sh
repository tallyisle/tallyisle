#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
SDK_MANAGER="${TALLYISLE_ANDROID_SDKMANAGER:-$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager}"
mkdir -p "$ANDROID_HOME/licenses" "$ANDROID_USER_HOME"
if [[ -d "$TALLYISLE_TOOLCHAIN/android-sdk/licenses" && "$TALLYISLE_TOOLCHAIN/android-sdk" != "$ANDROID_HOME" ]]; then
  cp -n "$TALLYISLE_TOOLCHAIN/android-sdk/licenses/"* "$ANDROID_HOME/licenses/" || true
fi
if [[ ! -f "$ANDROID_HOME/ndk/28.2.13676358/source.properties" ]]; then
  archive="$TALLYISLE_TOOLCHAIN/android-ndk-r28c-linux.zip"
  expected=dfb20d396df28ca02a8c708314b814a4d961dc9074f9a161932746f815aa552f
  if [[ ! -f "$archive" ]] || ! printf '%s  %s\n' "$expected" "$archive" | sha256sum --check --status; then
    curl -fL --max-time 900 https://dl.google.com/android/repository/android-ndk-r28c-linux.zip -o "$archive"
  fi
  printf '%s  %s\n' "$expected" "$archive" | sha256sum --check
  mkdir -p "$TALLYISLE_TOOLCHAIN/ndk" "$ANDROID_HOME/ndk"
  unzip -qn "$archive" -d "$TALLYISLE_TOOLCHAIN/ndk"
  if [[ -L "$ANDROID_HOME/ndk/28.2.13676358" ]]; then unlink "$ANDROID_HOME/ndk/28.2.13676358"; fi
  ln -s "$TALLYISLE_TOOLCHAIN/ndk/android-ndk-r28c" "$ANDROID_HOME/ndk/28.2.13676358"
fi
# Uses existing accepted licenses. Missing license approval remains an explicit
# SDKmanager error; this script never automatically answers license prompts.
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY "$SDK_MANAGER" --sdk_root="$ANDROID_HOME" 'platforms;android-36' 'build-tools;36.0.0'
