#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
SDK_MANAGER="${TALLYISLE_ANDROID_SDKMANAGER:-$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager}"
mkdir -p "$ANDROID_HOME/licenses" "$ANDROID_USER_HOME"
if [[ -d "$TALLYISLE_TOOLCHAIN/android-sdk/licenses" && "$TALLYISLE_TOOLCHAIN/android-sdk" != "$ANDROID_HOME" ]]; then
  cp -n "$TALLYISLE_TOOLCHAIN/android-sdk/licenses/"* "$ANDROID_HOME/licenses/" || true
fi

HOST_ARCH="$(uname -m)"

verify_or_download() {
  local url="$1"
  local archive="$2"
  local expected="$3"
  if [[ ! -f "$archive" ]] || ! printf '%s  %s\n' "$expected" "$archive" | sha256sum --check --status; then
    curl -fL --retry 3 --max-time 900 "$url" -o "$archive"
  fi
  printf '%s  %s\n' "$expected" "$archive" | sha256sum --check
}

if [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
  # Community native ARM64 (aarch64-linux-gnu) Android NDK r28c (28.2.13676358)
  if [[ ! -x "$ANDROID_HOME/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-arm64/bin/clang" ]]; then
    ndk_archive="$TALLYISLE_TOOLCHAIN/android-ndk-r28c-aarch64-linux-gnu.tar.xz"
    ndk_sha256="3e961b2dac764b0e326b271307e7059c2ef1ce3dac5223e75302400727cc046b"
    verify_or_download \
      "https://github.com/HomuHomu833/android-ndk-custom/releases/download/r28/android-ndk-r28c-aarch64-linux-gnu.tar.xz" \
      "$ndk_archive" \
      "$ndk_sha256"
    rm -rf "$TALLYISLE_TOOLCHAIN/ndk/android-ndk-r28c"
    mkdir -p "$TALLYISLE_TOOLCHAIN/ndk" "$ANDROID_HOME/ndk"
    tar -xJf "$ndk_archive" -C "$TALLYISLE_TOOLCHAIN/ndk"
    if [[ -L "$ANDROID_HOME/ndk/28.2.13676358" || -e "$ANDROID_HOME/ndk/28.2.13676358" ]]; then
      rm -rf "$ANDROID_HOME/ndk/28.2.13676358"
    fi
    ln -s "$TALLYISLE_TOOLCHAIN/ndk/android-ndk-r28c" "$ANDROID_HOME/ndk/28.2.13676358"
  fi
else
  # Official Google x86_64 Android NDK r28c (28.2.13676358)
  if [[ ! -f "$ANDROID_HOME/ndk/28.2.13676358/source.properties" ]]; then
    ndk_archive="$TALLYISLE_TOOLCHAIN/android-ndk-r28c-linux.zip"
    ndk_sha256="dfb20d396df28ca02a8c708314b814a4d961dc9074f9a161932746f815aa552f"
    verify_or_download \
      "https://dl.google.com/android/repository/android-ndk-r28c-linux.zip" \
      "$ndk_archive" \
      "$ndk_sha256"
    mkdir -p "$TALLYISLE_TOOLCHAIN/ndk" "$ANDROID_HOME/ndk"
    unzip -qn "$ndk_archive" -d "$TALLYISLE_TOOLCHAIN/ndk"
    if [[ -L "$ANDROID_HOME/ndk/28.2.13676358" ]]; then unlink "$ANDROID_HOME/ndk/28.2.13676358"; fi
    ln -s "$TALLYISLE_TOOLCHAIN/ndk/android-ndk-r28c" "$ANDROID_HOME/ndk/28.2.13676358"
  fi
fi

# Uses existing accepted licenses. Missing license approval remains an explicit
# SDKmanager error; this script never automatically answers license prompts.
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY "$SDK_MANAGER" --sdk_root="$ANDROID_HOME" \
  'platforms;android-36' 'platforms;android-35' 'build-tools;36.0.0' 'cmake;3.22.1' 'platform-tools'

# On ARM64 Linux hosts, replace Google's x86_64 SDK host binaries (build-tools,
# platform-tools, CMake 3.22.1 + Ninja, and Maven aapt2) with community native
# aarch64-linux-gnu builds while preserving sdkmanager package metadata.
if [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
  sdk_archive="$TALLYISLE_TOOLCHAIN/android-sdk-aarch64-linux-gnu-36.0.0.tar.xz"
  sdk_sha256="91de9261ce2520d64c5b65438999fcedb86a7b0e68e2082313897a848adf51d1"
  verify_or_download \
    "https://github.com/HomuHomu833/android-sdk-custom/releases/download/36.0.0/android-sdk-aarch64-linux-gnu.tar.xz" \
    "$sdk_archive" \
    "$sdk_sha256"

  cmake_archive="$TALLYISLE_TOOLCHAIN/cmake-3.22.1-aarch64-linux-gnu.tar.xz"
  cmake_sha256="bf97a68507d6bbe82462bf45fb140e2104815547e5112b7bf85ef9faf7696fde"
  verify_or_download \
    "https://github.com/HomuHomu833/cmake-custom/releases/download/3.22.1/cmake-aarch64-linux-gnu.tar.xz" \
    "$cmake_archive" \
    "$cmake_sha256"

  tmp_stage="$(mktemp -d)"
  trap 'rm -rf "$tmp_stage"' EXIT
  tar -xJf "$sdk_archive" -C "$tmp_stage"

  # 1. Install build-tools 36.1.0 and overlay native ARM64 tools onto 36.0.0
  rm -rf "$ANDROID_HOME/build-tools/36.1.0"
  cp -a "$tmp_stage/android-sdk/build-tools/36.1.0" "$ANDROID_HOME/build-tools/36.1.0"

  mkdir -p "$tmp_stage/meta-bt"
  cp -a "$ANDROID_HOME/build-tools/36.0.0/package.xml" "$tmp_stage/meta-bt/"
  cp -a "$ANDROID_HOME/build-tools/36.0.0/source.properties" "$tmp_stage/meta-bt/"
  rm -rf "$ANDROID_HOME/build-tools/36.0.0"
  cp -a "$tmp_stage/android-sdk/build-tools/36.1.0" "$ANDROID_HOME/build-tools/36.0.0"
  cp -af "$tmp_stage/meta-bt/package.xml" "$ANDROID_HOME/build-tools/36.0.0/package.xml"
  cp -af "$tmp_stage/meta-bt/source.properties" "$ANDROID_HOME/build-tools/36.0.0/source.properties"

  # 2. Overlay native ARM64 platform-tools while keeping package.xml / source.properties
  mkdir -p "$tmp_stage/meta-pt"
  cp -a "$ANDROID_HOME/platform-tools/package.xml" "$tmp_stage/meta-pt/"
  cp -a "$ANDROID_HOME/platform-tools/source.properties" "$tmp_stage/meta-pt/"
  rm -rf "$ANDROID_HOME/platform-tools"
  cp -a "$tmp_stage/android-sdk/platform-tools" "$ANDROID_HOME/platform-tools"
  cp -af "$tmp_stage/meta-pt/package.xml" "$ANDROID_HOME/platform-tools/package.xml"
  cp -af "$tmp_stage/meta-pt/source.properties" "$ANDROID_HOME/platform-tools/source.properties"

  # 3. Overlay native ARM64 CMake 3.22.1 + Ninja while keeping package.xml / source.properties
  mkdir -p "$tmp_stage/meta-cmake"
  cp -a "$ANDROID_HOME/cmake/3.22.1/package.xml" "$tmp_stage/meta-cmake/"
  cp -a "$ANDROID_HOME/cmake/3.22.1/source.properties" "$tmp_stage/meta-cmake/"
  rm -rf "$ANDROID_HOME/cmake/3.22.1"
  tar -xJf "$cmake_archive" -C "$ANDROID_HOME/cmake"
  cp -af "$tmp_stage/meta-cmake/package.xml" "$ANDROID_HOME/cmake/3.22.1/package.xml"
  cp -af "$tmp_stage/meta-cmake/source.properties" "$ANDROID_HOME/cmake/3.22.1/source.properties"

  # 4. Point AGP to native ARM64 aapt2 instead of Google Maven's x86_64 jar
  mkdir -p "$GRADLE_USER_HOME"
  touch "$GRADLE_USER_HOME/gradle.properties"
  grep -v '^android\.aapt2FromMavenOverride=' "$GRADLE_USER_HOME/gradle.properties" > "$tmp_stage/gradle.properties" || true
  printf 'android.aapt2FromMavenOverride=%s/build-tools/36.0.0/aapt2\n' "$ANDROID_HOME" >> "$tmp_stage/gradle.properties"
  mv "$tmp_stage/gradle.properties" "$GRADLE_USER_HOME/gradle.properties"
fi
