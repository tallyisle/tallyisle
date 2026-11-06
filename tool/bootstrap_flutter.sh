#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
if [[ ! -x "$FLUTTER_ROOT/bin/flutter" ]]; then
  git clone --depth 1 --branch 3.47.7 https://github.com/flutter/flutter.git "$FLUTTER_ROOT"
  git -C "$FLUTTER_ROOT" checkout -b stable
fi
flutter --version
python3 - <<'PY'
import subprocess,json
x=json.loads(subprocess.check_output(['flutter','--version','--machine']))
assert x['frameworkVersion']=='3.47.7' and x['dartSdkVersion']=='3.13.5',x
assert x['frameworkRevision']=='abaf9c523780a608bd46686fd5e53740a07077f8',x
assert x['channel']=='stable',x
print('Pinned Flutter/Dart verified.')
PY
