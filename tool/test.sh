#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$TALLYISLE_PROJECT"
flutter test --no-pub --reporter expanded "$@"
