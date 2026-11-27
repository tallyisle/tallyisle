#!/usr/bin/env bash
# Bumps the TallyIsle release version (ADR-019) in all version sources:
#   - pubspec.yaml                 `version: X.Y.Z+BUILD`
#   - lib/core/app_version.dart    `appVersionName` / `appBuildNumber`
#   - ohos/AppScope/app.json5      `versionName` / `versionCode` (if present)
#
# Usage:
#   bash tool/bump_version.sh 1.0.1          # build = MAJOR * 10000 + MINOR * 100 + PATCH (10001)
#   bash tool/bump_version.sh 1.0.1 10002    # explicit build number (must increase)
#   bash tool/bump_version.sh --show         # print current version
#
# Rules (1.0.0 formal release track):
#   - PATCH (Z) for bug fixes / small polish, MINOR (Y) for feature batches.
#   - Default BUILD = MAJOR * 10000 + MINOR * 100 + PATCH (requires MINOR < 100 and PATCH < 100).
#   - BUILD is a strictly increasing integer (Android versionCode); never reuse.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBSPEC="$ROOT/pubspec.yaml"
DART_FILE="$ROOT/lib/core/app_version.dart"
OHOS_APP_JSON5="$ROOT/ohos/AppScope/app.json5"

current_name="$(sed -n "s/^const String appVersionName = '\([^']*\)';/\1/p" "$DART_FILE")"
current_build="$(sed -n 's/^const int appBuildNumber = \([0-9][0-9]*\);/\1/p' "$DART_FILE")"
pubspec_version="$(sed -n 's/^version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$PUBSPEC")"

if [[ -z "$current_name" || -z "$current_build" || -z "$pubspec_version" ]]; then
  echo "error: cannot parse current version from $DART_FILE / $PUBSPEC" >&2
  exit 1
fi

if [[ "${1:-}" == "--show" ]]; then
  echo "app_version.dart : $current_name+$current_build"
  echo "pubspec.yaml     : $pubspec_version"
  if [[ -f "$OHOS_APP_JSON5" ]]; then
    ohos_name="$(sed -n 's/.*"versionName":[[:space:]]*"\([^"]*\)".*/\1/p' "$OHOS_APP_JSON5")"
    ohos_code="$(sed -n 's/.*"versionCode":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$OHOS_APP_JSON5")"
    echo "ohos/app.json5   : $ohos_name+$ohos_code"
  fi
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

new_name="$1"
if ! [[ "$new_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be plain MAJOR.MINOR.PATCH (got '$new_name')" >&2
  exit 1
fi

IFS='.' read -r major minor patch <<< "$new_name"
if [[ $# -eq 1 ]]; then
  if (( 10#$minor >= 100 || 10#$patch >= 100 )); then
    echo "error: default build formula requires MINOR < 100 and PATCH < 100 (got '$new_name'); pass an explicit build number as the 2nd argument" >&2
    exit 1
  fi
  new_build=$((10#$major * 10000 + 10#$minor * 100 + 10#$patch))
else
  new_build="$2"
fi

if ! [[ "$new_build" =~ ^[0-9]+$ ]] || (( 10#$new_build <= 10#$current_build )); then
  echo "error: build number must be an integer > $current_build (got '$new_build')" >&2
  exit 1
fi

# Reject semantic downgrades (e.g. 0.3.0 -> 0.2.9).
lowest="$(printf '%s\n%s\n' "$current_name" "$new_name" | sort -V | head -n1)"
if [[ "$lowest" == "$new_name" && "$new_name" != "$current_name" ]]; then
  echo "error: $new_name is lower than current $current_name" >&2
  exit 1
fi

sed -i "s/^version:.*/version: $new_name+$new_build/" "$PUBSPEC"
sed -i "s/^const String appVersionName = '[^']*';/const String appVersionName = '$new_name';/" "$DART_FILE"
sed -i "s/^const int appBuildNumber = [0-9][0-9]*;/const int appBuildNumber = $new_build;/" "$DART_FILE"
if [[ -f "$OHOS_APP_JSON5" ]]; then
  sed -i "s/\(\"versionCode\":[[:space:]]*\)[0-9][0-9]*/\1$new_build/" "$OHOS_APP_JSON5"
  sed -i "s/\(\"versionName\":[[:space:]]*\)\"[^\"]*\"/\1\"$new_name\"/" "$OHOS_APP_JSON5"
fi

echo "Bumped $current_name+$current_build -> $new_name+$new_build"
echo "Next: bash tool/check.sh && bash tool/build_android.sh, then commit 'Bump version to $new_name+$new_build'"
