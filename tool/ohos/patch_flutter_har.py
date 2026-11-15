#!/usr/bin/env python3
"""Patches CPF-Flutter's prebuilt flutter_embedding_*.har for public HarmonyOS SDK 21.

CPF-Flutter 3.47.7+ohos-0.0.1-pre builds flutter_embedding_*.har against Huawei's
internal API 26 SDK while guarding API 22/24/26 calls at runtime via
deviceInfo.sdkApiVersion checks. Three .ets files in that HAR still reference
API 22/24/26 TypeScript declarations directly without ESObject casts, causing
18 ArkTS type-check errors when compiled against public Command Line Tools 6.0.1 (API 21).

This script rewrites only those compile-time type annotations / calls inside
flutter_embedding_*.har while preserving identical runtime behavior on all API levels.
"""

from __future__ import annotations

import io
import os
import pathlib
import re
import shutil
import sys
import tarfile
import tempfile

AUTOFILL_FILE = "package/src/main/ets/plugin/editing/OhosAutoFillHelper.ets"
EMBEDDING_NODE_FILE = "package/src/main/ets/embedding/ohos/EmbeddingNodeController.ets"
FLUTTER_MANAGER_FILE = "package/src/main/ets/embedding/ohos/FlutterManager.ets"

AUTOFILL_REPLACEMENTS: list[tuple[str, str]] = [
    (
        """interface AutoFillManagerPageNodeInfo {
  id: number;
  depth: number;
  autoFillType: autoFillManager.AutoFillType;
  tag: string;
  value: string;
  placeholder: string;
  enableAutoFill: boolean;
  rect: OhosAutoFillRect;
  isFocus: boolean;
}

interface AutoFillManagerViewData {
  bundleName: string;
  moduleName: string;
  abilityName: string;
  pageUrl: string;
  pageNodeInfos: AutoFillManagerPageNodeInfo[];
  pageRect: OhosAutoFillRect;
  isUserSelected: boolean;
  isOtherAccount: boolean;
}

interface AutoFillCustomData {
  data: Record<string, string>;
}""",
        """interface AutoFillManagerPageNodeInfo {
  id: number;
  depth: number;
  autoFillType: number;
  tag: string;
  value: string;
  placeholder: string;
  enableAutoFill: boolean;
  rect: OhosAutoFillRect;
  isFocus: boolean;
}

interface AutoFillManagerViewData {
  bundleName: string;
  moduleName: string;
  abilityName: string;
  pageUrl: string;
  pageNodeInfos: AutoFillManagerPageNodeInfo[];
  pageRect: OhosAutoFillRect;
  isUserSelected: boolean;
  isOtherAccount: boolean;
}

interface AutoFillCustomData {
  data: Record<string, string>;
}

interface AutoFillFailureResultCompat {
  errCode: number;
}

interface AutoFillRequestCompat {
  type: number;
  viewData: AutoFillManagerViewData;
  customData: AutoFillCustomData;
  isPopup: boolean;
  triggerType: number;
}

interface AutoSaveRequestCompat {
  viewData: AutoFillManagerViewData;
}

class AutoFillCallbackCompat {
  onSuccess: (filledViewData: AutoFillManagerViewData) => void;
  onFailure: (result: AutoFillFailureResultCompat) => void;

  constructor(
    onSuccess: (filledViewData: AutoFillManagerViewData) => void,
    onFailure: (result: AutoFillFailureResultCompat) => void,
  ) {
    this.onSuccess = onSuccess;
    this.onFailure = onFailure;
  }
}""",
    ),
    (
        """  private static toSdkAutoFillType(value: number): autoFillManager.AutoFillType {
    return value as autoFillManager.AutoFillType;
  }""",
        """  private static toSdkAutoFillType(value: number): number {
    return value;
  }""",
    ),
    (
        """  private static toManagerViewData(viewData: OhosViewData): autoFillManager.ViewData {
    const pageNodeInfos: AutoFillManagerPageNodeInfo[] = [];
    for (const node of viewData.pageNodeInfos) {
      pageNodeInfos.push(OhosAutoFillHelper.toManagerPageNodeInfo(node));
    }
    const managerViewData: AutoFillManagerViewData = {
      bundleName: viewData.bundleName,
      moduleName: viewData.moduleName,
      abilityName: viewData.abilityName,
      pageUrl: viewData.pageUrl,
      pageNodeInfos: pageNodeInfos,
      pageRect: viewData.pageRect,
      isUserSelected: viewData.isUserSelected,
      isOtherAccount: viewData.isOtherAccount,
    };
    return managerViewData as autoFillManager.ViewData;
  }

  static parseFillResult(viewData: autoFillManager.ViewData): Map<number, string> {
    const values: Map<number, string> = new Map();
    const pageNodeInfos: OhosPageNodeInfo[] =
      (viewData as AutoFillManagerViewData).pageNodeInfos;""",
        """  private static toManagerViewData(viewData: OhosViewData): AutoFillManagerViewData {
    const pageNodeInfos: AutoFillManagerPageNodeInfo[] = [];
    for (const node of viewData.pageNodeInfos) {
      pageNodeInfos.push(OhosAutoFillHelper.toManagerPageNodeInfo(node));
    }
    const managerViewData: AutoFillManagerViewData = {
      bundleName: viewData.bundleName,
      moduleName: viewData.moduleName,
      abilityName: viewData.abilityName,
      pageUrl: viewData.pageUrl,
      pageNodeInfos: pageNodeInfos,
      pageRect: viewData.pageRect,
      isUserSelected: viewData.isUserSelected,
      isOtherAccount: viewData.isOtherAccount,
    };
    return managerViewData;
  }

  static parseFillResult(viewData: AutoFillManagerViewData): Map<number, string> {
    const values: Map<number, string> = new Map();
    const pageNodeInfos: AutoFillManagerPageNodeInfo[] = viewData.pageNodeInfos;""",
    ),
    (
        """    const fillRequest = {
      type: OhosAutoFillHelper.toSdkAutoFillType(autoFillType),
      viewData: managerViewData,
      customData: OhosAutoFillHelper.createEmptyCustomData(),
      isPopup: false,
      triggerType: AUTOFILL_TRIGGER_AUTO_REQUEST as autoFillManager.AutoFillTriggerType,
    } as autoFillManager.FillRequest;
    const callback: autoFillManager.AutoFillCallback = {
      onSuccess: (filledViewData: autoFillManager.ViewData): void => {
        const values = OhosAutoFillHelper.parseFillResult(filledViewData);
        onSuccess(values);
      },
      onFailure: (result: autoFillManager.FillFailureResult): void => {
        Log.e(TAG, 'requestAutoFill onFailure: ' + JSON.stringify(result));
        onFailure(result.errCode);
      },
    };
    try {
      autoFillManager.requestAutoFill(uiContext, fillRequest, callback);""",
        """    const fillRequest: AutoFillRequestCompat = {
      type: OhosAutoFillHelper.toSdkAutoFillType(autoFillType),
      viewData: managerViewData,
      customData: OhosAutoFillHelper.createEmptyCustomData(),
      isPopup: false,
      triggerType: AUTOFILL_TRIGGER_AUTO_REQUEST,
    };
    const callback: AutoFillCallbackCompat = new AutoFillCallbackCompat(
      (filledViewData: AutoFillManagerViewData): void => {
        const values = OhosAutoFillHelper.parseFillResult(filledViewData);
        onSuccess(values);
      },
      (result: AutoFillFailureResultCompat): void => {
        Log.e(TAG, 'requestAutoFill onFailure: ' + JSON.stringify(result));
        onFailure(result.errCode);
      },
    );
    try {
      (autoFillManager as ESObject).requestAutoFill(uiContext, fillRequest, callback);""",
    ),
    (
        """    const saveRequest: autoFillManager.SaveRequest = {
      viewData: OhosAutoFillHelper.toManagerViewData(viewData),
    };
    const validation = OhosAutoFillHelper.validateSaveViewData(viewData);
    if (validation !== 'ok') {
      Log.e(TAG, 'requestAutoSave aborted: invalid ViewData reason=' + validation);
      napiCallback.onFailure();
      return;
    }
    try {
      autoFillManager.requestAutoSave(uiContext, saveRequest, napiCallback);""",
        """    const saveRequest: AutoSaveRequestCompat = {
      viewData: OhosAutoFillHelper.toManagerViewData(viewData),
    };
    const validation = OhosAutoFillHelper.validateSaveViewData(viewData);
    if (validation !== 'ok') {
      Log.e(TAG, 'requestAutoSave aborted: invalid ViewData reason=' + validation);
      napiCallback.onFailure();
      return;
    }
    try {
      (autoFillManager as ESObject).requestAutoSave(uiContext, saveRequest, napiCallback);""",
    ),
]


def _patch_autofill(src: str) -> str:
    if "class AutoFillCallbackCompat" in src:
        return src
    out = src
    for idx, (target, replacement) in enumerate(AUTOFILL_REPLACEMENTS, 1):
        if target not in out:
            raise RuntimeError(
                f"Expected block #{idx} not found in {AUTOFILL_FILE}"
            )
        out = out.replace(target, replacement, 1)
    code_only = re.sub(r"/\*.*?\*/|//[^\n]*", "", out, flags=re.DOTALL)
    for forbidden in (
        "autoFillManager.AutoFillType",
        "autoFillManager.ViewData",
        "autoFillManager.AutoFillTriggerType",
        "autoFillManager.FillRequest",
        "autoFillManager.AutoFillCallback",
        "autoFillManager.FillFailureResult",
        "autoFillManager.SaveRequest",
        "autoFillManager.requestAutoFill(",
        "autoFillManager.requestAutoSave(",
    ):
        if forbidden in code_only:
            raise RuntimeError(f"Unpatched symbol {forbidden!r} remains in {AUTOFILL_FILE}")
    return out


def _patch_embedding_node(src: str) -> str:
    if "CompetitionStrategy.DEFAULT" not in src:
        if "postInputEventWithStrategy(event, 0)" in src:
            return src
        raise RuntimeError(f"Expected CompetitionStrategy.DEFAULT in {EMBEDDING_NODE_FILE}")
    out = src.replace("CompetitionStrategy.DEFAULT", "0")
    if "CompetitionStrategy" in out:
        raise RuntimeError(f"Unpatched CompetitionStrategy remains in {EMBEDDING_NODE_FILE}")
    return out


def _patch_flutter_manager(src: str) -> str:
    target = "return mainWindow.isInFreeWindowMode();"
    replacement = "return (mainWindow as ESObject)?.isInFreeWindowMode() === true;"
    if target not in src:
        if replacement in src:
            return src
        raise RuntimeError(f"Expected {target!r} in {FLUTTER_MANAGER_FILE}")
    out = src.replace(target, replacement, 1)
    if "mainWindow.isInFreeWindowMode()" in out:
        raise RuntimeError(f"Unpatched isInFreeWindowMode call remains in {FLUTTER_MANAGER_FILE}")
    return out


def patch_har_file(har_path: pathlib.Path) -> bool:
    patchers = {
        AUTOFILL_FILE: _patch_autofill,
        EMBEDDING_NODE_FILE: _patch_embedding_node,
        FLUTTER_MANAGER_FILE: _patch_flutter_manager,
    }
    seen: set[str] = set()
    changed = False

    fd, tmp_name = tempfile.mkstemp(suffix=".har", dir=str(har_path.parent))
    os.close(fd)
    tmp_path = pathlib.Path(tmp_name)
    try:
        with tarfile.open(har_path, "r:gz") as src_tar, tarfile.open(tmp_path, "w:gz") as dst_tar:
            for member in src_tar.getmembers():
                extracted = src_tar.extractfile(member) if member.isfile() else None
                if member.name in patchers and extracted is not None:
                    seen.add(member.name)
                    original_text = extracted.read().decode("utf-8")
                    patched_text = patchers[member.name](original_text)
                    if patched_text != original_text:
                        changed = True
                    payload = patched_text.encode("utf-8")
                    new_info = tarfile.TarInfo(name=member.name)
                    new_info.size = len(payload)
                    new_info.mode = member.mode
                    new_info.mtime = member.mtime
                    new_info.uid = member.uid
                    new_info.gid = member.gid
                    new_info.uname = member.uname
                    new_info.gname = member.gname
                    new_info.type = member.type
                    dst_tar.addfile(new_info, io.BytesIO(payload))
                elif extracted is not None:
                    dst_tar.addfile(member, extracted)
                else:
                    dst_tar.addfile(member)

        missing = set(patchers) - seen
        if missing:
            raise RuntimeError(f"{har_path}: missing expected archive entries: {sorted(missing)}")

        shutil.move(str(tmp_path), str(har_path))
        return changed
    except Exception:
        if tmp_path.exists():
            tmp_path.unlink()
        raise


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"Usage: {argv[0]} <engine-artifacts-dir-or-har-file>", file=sys.stderr)
        return 2

    root = pathlib.Path(argv[1])
    if root.is_file():
        har_files = [root]
    elif root.is_dir():
        har_files = sorted(root.rglob("flutter_embedding_*.har"))
    else:
        print(f"Path does not exist: {root}", file=sys.stderr)
        return 1

    if not har_files:
        print(f"No flutter_embedding_*.har files found under {root}", file=sys.stderr)
        return 1

    for har in har_files:
        changed = patch_har_file(har)
        status = "patched" if changed else "already-compatible"
        print(f"[{status}] {har}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
