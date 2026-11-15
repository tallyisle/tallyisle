#!/usr/bin/env bash
set -euo pipefail

echo "========================================================"
echo "  帐屿 / TallyIsle — 鸿蒙真机一键安装助手 (macOS / Linux)"
echo "========================================================"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Locate hdc
HDC_CMD=""
if command -v hdc >/dev/null 2>&1; then
  HDC_CMD="$(command -v hdc)"
else
  for candidate in \
    "$SCRIPT_DIR/hdc" \
    "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc" \
    "$HOME/Library/Huawei/Sdk/default/openharmony/toolchains/hdc" \
    "${DEVECO_SDK_HOME:-}/default/openharmony/toolchains/hdc"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      HDC_CMD="$candidate"
      break
    fi
  done
fi

if [[ -z "$HDC_CMD" ]]; then
  echo "[错误] 未找到鸿蒙调试工具 hdc。"
  echo "请先安装 DevEco Studio，或将 toolchains/hdc 加入 PATH 后重试。"
  exit 1
fi

echo "[1/3] 已找到调试工具: $HDC_CMD"

# 2. Locate HAP file
HAP_FILE="${1:-}"
if [[ -z "$HAP_FILE" ]]; then
  for pattern in \
    "$SCRIPT_DIR"/*已签名*.hap \
    "$SCRIPT_DIR"/*signed*.hap \
    "$PWD"/*已签名*.hap \
    "$PWD"/*signed*.hap \
    "$HOME/Downloads"/*帐屿*已签名*.hap \
    "$SCRIPT_DIR"/*.hap \
    "$PWD"/*.hap; do
    if [[ -f "$pattern" ]]; then
      HAP_FILE="$pattern"
      break
    fi
  done
fi

if [[ -z "$HAP_FILE" || ! -f "$HAP_FILE" ]]; then
  echo "[错误] 未找到 .hap 安装包。"
  echo "用法: bash $0 /path/to/帐屿-HarmonyOS-已签名调试版.hap"
  exit 1
fi

if [[ "$HAP_FILE" == *"unsigned"* || "$HAP_FILE" == *"未签名"* ]]; then
  echo "[警告] 检测到未签名安装包: $HAP_FILE"
  echo "鸿蒙真机无法直接安装未签名包（会报错 9568320）。请使用已签名调试版 .hap！"
  echo ""
fi

echo "[2/3] 准备安装包: $HAP_FILE"

# 3. Check connected device
TARGETS="$("$HDC_CMD" list targets 2>/dev/null | tr -d '\r' || true)"
if [[ -z "$TARGETS" || "$TARGETS" == *"[Empty]"* ]]; then
  echo "[错误] 未检测到已连接的鸿蒙设备！"
  echo "请确认："
  echo "  1. 手机已通过数据线连接电脑；"
  echo "  2. 手机「设置 - 系统 - 开发者选项」已开启「USB 调试」；"
  echo "  3. 手机屏幕已解锁并在弹窗中点击「允许 USB 调试」。"
  exit 1
fi

echo "已连接设备: $TARGETS"
echo ""
echo "[3/3] 正在安装帐屿到手机，请稍候..."
"$HDC_CMD" install -r "$HAP_FILE"
echo ""
echo "========================================================"
echo "  安装完成！现在可以在鸿蒙手机桌面上打开「帐屿」体验了。"
echo "========================================================"
