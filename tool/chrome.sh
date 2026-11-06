#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/browser_env.sh"
exec "${TALLYISLE_CHROME:-$TALLYISLE_BROWSER_ROOT/browsers/chromium-1194/chrome-linux/chrome}" --no-sandbox "$@"
