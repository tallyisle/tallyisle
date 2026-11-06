#!/usr/bin/env bash
# Isolated Chromium dependencies. Never change system fonts, keyboard data or SDK.
export TALLYISLE_BROWSER_ROOT="${TALLYISLE_BROWSER_ROOT:-/tmp/tallyisle-browser}"
export LD_LIBRARY_PATH="$TALLYISLE_BROWSER_ROOT/libs/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if test -d "$TALLYISLE_BROWSER_ROOT/libs/usr/share/X11/xkb"; then
  export XKB_CONFIG_ROOT="$TALLYISLE_BROWSER_ROOT/libs/usr/share/X11/xkb"
fi
if test -d "$TALLYISLE_BROWSER_ROOT/libs/usr/share/fonts"; then
  export FONTCONFIG_FILE="$TALLYISLE_BROWSER_ROOT/fontconfig-tallyisle.conf"
  python3 - <<'PY'
import os,pathlib,xml.sax.saxutils
root=pathlib.Path(os.environ['TALLYISLE_BROWSER_ROOT'])
escape=xml.sax.saxutils.escape
pathlib.Path(os.environ['FONTCONFIG_FILE']).write_text(
 '<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd"><fontconfig>'
 f'<dir>{escape(str(root / "libs/usr/share/fonts"))}</dir>'
 f'<cachedir>{escape(str(root / "fontcache-tallyisle"))}</cachedir></fontconfig>')
PY
fi
if test -d /tmp/tallyisle-node/node-v22.16.0-linux-x64/bin; then
  export PATH="/tmp/tallyisle-node/node-v22.16.0-linux-x64/bin:$PATH"
fi
