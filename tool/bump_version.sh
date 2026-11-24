#!/usr/bin/env bash
# Bumps the TallyIsle release version (ADR-019) in both single sources:
#   - pubspec.yaml                 `version: X.Y.Z+BUILD`
#   - lib/core/app_version.dart    `appVersionName` / `appBuildNumber`
#
# Usage:
#   bash tool/bump_version.sh 0.2.1          # build number = current + 1
#   bash tool/bump_version.sh 0.3.0 7        # explicit build number (must increase)
#   bash tool/bump_version.sh --show         # print current version
#
# Rules (plan A, 0.x.y track until real-device acceptance, then 1.0.0):
#   - PATCH (Z) for bug fixes / small polish, MINOR (Y) for feature batches.
#   - BUILD is a strictly increasing integer (Android versionCode); never reuse.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBSPEC="$ROOT/pubspec.yaml"
DART_FILE="$ROOT/lib/core/app_version.dart"

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
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

new_name="$1"
new_build="${2:-$((current_build + 1))}"

if ! [[ "$new_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be plain MAJOR.MINOR.PATCH (got '$new_name')" >&2
  exit 1
fi
if ! [[ "$new_build" =~ ^[0-9]+$ ]] || (( new_build <= current_build )); then
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

echo "Bumped $current_name+$current_build -> $new_name+$new_build"
echo "Next: bash tool/check.sh && bash tool/build_android.sh, then commit 'Bump version to $new_name+$new_build'"
