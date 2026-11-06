#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$TALLYISLE_PROJECT"
flutter pub get --enforce-lockfile
dart run build_runner build
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test --no-pub --reporter expanded
