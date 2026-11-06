#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$TALLYISLE_PROJECT"
flutter pub get --enforce-lockfile
flutter build apk --debug --no-pub --target-platform android-arm64 "$@"
