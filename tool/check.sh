#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$TALLYISLE_PROJECT"
flutter pub get --enforce-lockfile --offline
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub lib test
flutter test --no-pub --reporter expanded
