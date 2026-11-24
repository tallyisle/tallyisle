#!/usr/bin/env python3
"""Idempotent mount/restore helper for HarmonyOS NEXT pubspec overrides.

Keeps repository-root `pubspec.yaml` and `pubspec.lock` 100% pure for the five
upstream Flutter targets (Android, iOS, Windows, Linux, macOS), while mounting
HarmonyOS `dependency_overrides`, `sqlite3` build hooks, and
`tool/ohos/pubspec_ohos.lock` on demand during HarmonyOS verification/builds.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys

MARKER_BEGIN = (
    "# BEGIN TALLYISLE_OHOS_OVERRIDES "
    "(managed by tool/ohos/apply_ohos_pubspec.py)"
)
MARKER_END = "# END TALLYISLE_OHOS_OVERRIDES"

OHOS_PUBSPEC_SECTION = f"""{MARKER_BEGIN}
dependency_overrides:
  code_assets:
    path: third_party/ohos_packages/code_assets
  cupertino_ui:
    path: third_party/ohos_packages/cupertino_ui
  material_ui:
    path: third_party/ohos_packages/material_ui
  path_provider:
    path: third_party/ohos_packages/path_provider
  path_provider_ohos:
    path: third_party/ohos_packages/path_provider_ohos
  file_selector:
    path: third_party/ohos_packages/file_selector
  file_selector_ohos:
    path: third_party/ohos_packages/file_selector_ohos

hooks:
  user_defines:
    sqlite3:
      source:
        ohos: system
        default: sqlite3
{MARKER_END}"""

_MARKED_BLOCK_RE = re.compile(
    r"\n*"
    + re.escape(MARKER_BEGIN)
    + r"[\s\S]*?"
    + re.escape(MARKER_END)
    + r"[ \t]*\n?",
)


def _strip_top_level_block(lines: list[str], key: str, needle: str) -> list[str]:
    """Removes a top-level YAML mapping block `key:` if its body contains `needle`."""
    out: list[str] = []
    i = 0
    header = f"{key}:"
    while i < len(lines):
        line = lines[i]
        if line.rstrip() == header:
            j = i + 1
            while j < len(lines):
                nxt = lines[j]
                if nxt.strip() == "" or nxt.startswith((" ", "\t", "#")):
                    j += 1
                else:
                    break
            block_text = "".join(lines[i:j])
            if needle in block_text:
                while out and out[-1].strip() == "":
                    out.pop()
                i = j
                continue
        out.append(line)
        i += 1
    return out


def strip_ohos_pubspec(pubspec_text: str) -> str:
    """Returns `pubspec.yaml` content with all HarmonyOS-specific sections removed."""
    cleaned = _MARKED_BLOCK_RE.sub("\n", pubspec_text)
    lines = cleaned.splitlines(keepends=True)
    lines = _strip_top_level_block(
        lines, "dependency_overrides", "third_party/ohos_packages/"
    )
    lines = _strip_top_level_block(lines, "hooks", "ohos: system")
    result = "".join(lines).rstrip() + "\n"
    return result


def is_ohos_lockfile(lock_text: str) -> bool:
    return "third_party/ohos_packages/" in lock_text


def apply_ohos(root: Path) -> None:
    pubspec_path = root / "pubspec.yaml"
    lock_path = root / "pubspec.lock"
    ohos_lock_path = root / "tool" / "ohos" / "pubspec_ohos.lock"
    backup_dir = root / ".dart_tool" / "ohos_pubspec_backup"
    pubspec_backup = backup_dir / "pubspec.yaml.orig"
    lock_backup = backup_dir / "pubspec.lock.orig"

    if not pubspec_path.is_file():
        raise FileNotFoundError(f"Missing pubspec.yaml at {pubspec_path}")
    if not ohos_lock_path.is_file():
        raise FileNotFoundError(
            f"Missing HarmonyOS lockfile at {ohos_lock_path}"
        )

    current_pubspec = pubspec_path.read_text(encoding="utf-8")
    clean_pubspec = strip_ohos_pubspec(current_pubspec)

    backup_dir.mkdir(parents=True, exist_ok=True)
    if not pubspec_backup.is_file():
        # Preserve exact original bytes when clean, otherwise normalized clean text.
        orig_pubspec = (
            current_pubspec
            if current_pubspec == clean_pubspec
            else clean_pubspec
        )
        pubspec_backup.write_text(orig_pubspec, encoding="utf-8")

    if lock_path.is_file() and not lock_backup.is_file():
        current_lock = lock_path.read_text(encoding="utf-8")
        if not is_ohos_lockfile(current_lock):
            lock_backup.write_text(current_lock, encoding="utf-8")

    target_pubspec = clean_pubspec.rstrip("\n") + "\n\n" + OHOS_PUBSPEC_SECTION + "\n"
    if current_pubspec != target_pubspec:
        pubspec_path.write_text(target_pubspec, encoding="utf-8")

    ohos_lock_text = ohos_lock_path.read_text(encoding="utf-8")
    if not lock_path.is_file() or lock_path.read_text(encoding="utf-8") != ohos_lock_text:
        lock_path.write_text(ohos_lock_text, encoding="utf-8")


def _git_head_official_lockfile(root: Path) -> str | None:
    proc = subprocess.run(
        ["git", "-C", str(root), "show", "HEAD:pubspec.lock"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode == 0 and proc.stdout and not is_ohos_lockfile(proc.stdout):
        return proc.stdout
    return None


def restore_official(root: Path) -> None:
    pubspec_path = root / "pubspec.yaml"
    lock_path = root / "pubspec.lock"
    backup_dir = root / ".dart_tool" / "ohos_pubspec_backup"
    pubspec_backup = backup_dir / "pubspec.yaml.orig"
    lock_backup = backup_dir / "pubspec.lock.orig"

    if not pubspec_path.is_file():
        raise FileNotFoundError(f"Missing pubspec.yaml at {pubspec_path}")

    current_pubspec = pubspec_path.read_text(encoding="utf-8")
    if pubspec_backup.is_file():
        restored_pubspec = strip_ohos_pubspec(
            pubspec_backup.read_text(encoding="utf-8")
        )
    else:
        restored_pubspec = strip_ohos_pubspec(current_pubspec)

    if current_pubspec != restored_pubspec:
        pubspec_path.write_text(restored_pubspec, encoding="utf-8")

    if lock_backup.is_file():
        restored_lock = lock_backup.read_text(encoding="utf-8")
        if not lock_path.is_file() or lock_path.read_text(encoding="utf-8") != restored_lock:
            lock_path.write_text(restored_lock, encoding="utf-8")
    elif lock_path.is_file() and is_ohos_lockfile(
        lock_path.read_text(encoding="utf-8")
    ):
        head_lock = _git_head_official_lockfile(root)
        if head_lock is None:
            raise RuntimeError(
                "Cannot restore official pubspec.lock: backup missing and "
                "HEAD:pubspec.lock is unavailable."
            )
        lock_path.write_text(head_lock, encoding="utf-8")

    if backup_dir.exists():
        shutil.rmtree(backup_dir)

    final_pubspec = pubspec_path.read_text(encoding="utf-8")
    if "third_party/ohos_packages/" in final_pubspec or "ohos: system" in final_pubspec:
        raise RuntimeError("pubspec.yaml still contains HarmonyOS overrides after --restore")
    if lock_path.is_file() and is_ohos_lockfile(lock_path.read_text(encoding="utf-8")):
        raise RuntimeError("pubspec.lock still contains HarmonyOS overrides after --restore")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Mount or restore HarmonyOS pubspec overrides and lockfile."
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--apply",
        action="store_true",
        help="Inject HarmonyOS dependency_overrides + sqlite3 hooks and pubspec_ohos.lock.",
    )
    mode.add_argument(
        "--restore",
        action="store_true",
        help="Restore pure upstream pubspec.yaml and pubspec.lock.",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="Project root directory (defaults to repository root).",
    )
    args = parser.parse_args(argv)
    root = args.root.resolve()

    if args.apply:
        apply_ohos(root)
    elif args.restore:
        restore_official(root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
