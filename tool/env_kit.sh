#!/usr/bin/env bash
# Pack or restore TallyIsle's non-git environment overlay & sanitized config templates.
# Usage:
#   bash tool/env_kit.sh pack [output.tar.gz]
#   bash tool/env_kit.sh restore <input.tar.gz> [--apply-user-config]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$PROJECT_DIR/.." && pwd)"

cmd="${1:-}"

pack_kit() {
  local out="${1:-/tmp/tallyisle-env-kit.tar.gz}"
  mkdir -p "$PROJECT_DIR/.env-kit" "$(dirname "$out")"

  cat <<'JSON' > "$PROJECT_DIR/.env-kit/gemini-config.template.json"
{
  "plugins": {
    "gdrive": {
      "installedFrom": {
        "id": "antigravity-plugins-official/plugin/gdrive",
        "marketplace": "antigravity-plugins-official",
        "version": "0.0.11"
      }
    },
    "swarm": {
      "enabled": true
    }
  }
}
JSON

  cat <<'JSON' > "$PROJECT_DIR/.env-kit/antigravity-settings.template.json"
{
  "allowNonWorkspaceAccess": true,
  "toolPermission": "always-proceed",
  "trustedWorkspaces": [
    "__WORKSPACE_DIR__"
  ]
}
JSON

  cat <<'GITCFG' > "$PROJECT_DIR/.env-kit/gitconfig.template"
[credential "https://github.com"]
	helper =
	helper = !/usr/bin/gh auth git-credential
[credential "https://gist.github.com"]
	helper =
	helper = !/usr/bin/gh auth git-credential
GITCFG

  (
    cd "$PROJECT_DIR"
    : > .env-kit/MANIFEST.sha256
    for target in \
      tool/seeds/android-user/debug.keystore \
      tool/seeds/gradle-init/tallyisle-offline.gradle \
      tool/seeds/sqlite-hooks/download-1ff25026/libsqlite3.so \
      tool/seeds/sqlite-hooks/download-b372f69d/libsqlite3.so \
      tool/seeds/sqlite-hooks/download-c2858e70/libsqlite3.so \
      reference/*.apk
    do
      if [[ -f "$target" ]]; then
        sha256sum "$target" >> .env-kit/MANIFEST.sha256
      fi
    done

    items=()
    for entry in AGENTS.md docs archive reference tool/seeds .env-kit; do
      if [[ -e "$entry" ]]; then
        items+=("$entry")
      fi
    done
    tar -czf "$out" "${items[@]}"
  )

  ls -lh "$out"
  sha256sum "$out"
}

restore_kit() {
  local archive="${1:-}"
  local apply_cfg="${2:-}"
  if [[ -z "$archive" || ! -f "$archive" ]]; then
    echo "Usage: bash tool/env_kit.sh restore <tallyisle-env-kit.tar.gz> [--apply-user-config]" >&2
    exit 1
  fi

  tar -xzf "$archive" -C "$PROJECT_DIR"

  if [[ -f "$PROJECT_DIR/.env-kit/MANIFEST.sha256" ]]; then
    (cd "$PROJECT_DIR" && sha256sum --check .env-kit/MANIFEST.sha256)
  fi

  if [[ "$apply_cfg" == "--apply-user-config" ]]; then
    mkdir -p "$HOME/.gemini/config" "$HOME/.gemini/antigravity-cli"
    if [[ ! -s "$HOME/.gemini/config/config.json" && -f "$PROJECT_DIR/.env-kit/gemini-config.template.json" ]]; then
      cp "$PROJECT_DIR/.env-kit/gemini-config.template.json" "$HOME/.gemini/config/config.json"
    fi
    if [[ ! -s "$HOME/.gemini/antigravity-cli/settings.json" && -f "$PROJECT_DIR/.env-kit/antigravity-settings.template.json" ]]; then
      sed "s|__WORKSPACE_DIR__|$WORKSPACE_DIR|g" \
        "$PROJECT_DIR/.env-kit/antigravity-settings.template.json" \
        > "$HOME/.gemini/antigravity-cli/settings.json"
    fi
  fi

  # Seed debug.keystore, android-licenses, gradle-init, and sqlite native hooks.
  source "$SCRIPT_DIR/env.sh"
  if [[ -d "$PROJECT_DIR/tool/seeds/gradle-init" ]]; then
    mkdir -p "$GRADLE_USER_HOME/init.d"
    cp -f "$PROJECT_DIR/tool/seeds/gradle-init/"* "$GRADLE_USER_HOME/init.d/" 2>/dev/null || true
  fi
  echo "==> TallyIsle environment overlay restored and verified in $PROJECT_DIR"
}

case "$cmd" in
  pack)
    pack_kit "${2:-/tmp/tallyisle-env-kit.tar.gz}"
    ;;
  restore)
    restore_kit "${2:-}" "${3:-}"
    ;;
  *)
    echo "Usage: bash tool/env_kit.sh {pack [out.tar.gz] | restore <in.tar.gz> [--apply-user-config]}" >&2
    exit 1
    ;;
esac
