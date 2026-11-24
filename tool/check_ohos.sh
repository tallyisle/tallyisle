#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env_ohos.sh"
cd "$TALLYISLE_PROJECT"

restore_pubspec() {
  local rc=$?
  trap - EXIT INT TERM
  if ! python3 "$TALLYISLE_PROJECT/tool/ohos/apply_ohos_pubspec.py" --restore; then
    exit 1
  fi
  exit "$rc"
}
trap 'exit 130' INT
trap 'exit 143' TERM
trap restore_pubspec EXIT

python3 "$TALLYISLE_PROJECT/tool/ohos/apply_ohos_pubspec.py" --apply
flutter pub get --enforce-lockfile --offline
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub lib test
flutter test --no-pub --reporter expanded
