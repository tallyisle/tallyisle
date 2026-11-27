#!/usr/bin/env bash
set -euo pipefail

echo "========================================================"
echo "  帐屿 / TallyIsle — 鸿蒙设备一键安装助手 (macOS / Linux)"
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

echo "[1/4] 已找到调试工具: $HDC_CMD"

# 2. Check connected device
TARGETS="$("$HDC_CMD" list targets 2>/dev/null | tr -d '\r' || true)"
if [[ -z "$TARGETS" || "$TARGETS" == *"[Empty]"* ]]; then
  echo "[错误] 未检测到已连接的鸿蒙设备！"
  echo "请确认："
  echo "  1. 手机已通过数据线连接电脑（或已启动 DevEco 模拟器）；"
  echo "  2. 手机「设置 - 系统 - 开发者选项」已开启「USB 调试」；"
  echo "  3. 手机屏幕已解锁并在弹窗中点击「允许 USB 调试」。"
  exit 1
fi

echo "[2/4] 已连接设备: $TARGETS"

# 3. Detect device ABI via const.product.cpu.abilist
ABILIST="$("$HDC_CMD" shell param get const.product.cpu.abilist 2>/dev/null | tr -d '\r\n' | xargs || true)"
PRIMARY_ABI="${ABILIST%%,*}"
TARGET_ARCH="arm64"
if [[ "$PRIMARY_ABI" == "x86_64" ]]; then
  TARGET_ARCH="x64"
elif [[ "$PRIMARY_ABI" == "arm64-v8a" ]]; then
  TARGET_ARCH="arm64"
elif [[ "$ABILIST" == *"x86_64"* && "$ABILIST" != *"arm64-v8a"* ]]; then
  TARGET_ARCH="x64"
fi

echo "[3/4] 设备 ABI: ${ABILIST:-未知 (默认回退 arm64-v8a)} -> 选择架构: $TARGET_ARCH"

# 4. Locate HAP file matching target arch (or explicit $1)
HAP_FILE="${1:-}"
if [[ -z "$HAP_FILE" ]]; then
  shopt -s nullglob
  for candidate in \
    "$SCRIPT_DIR/TallyIsle-HarmonyOS-${TARGET_ARCH}-signed-debug.hap" \
    "$SCRIPT_DIR"/*-"${TARGET_ARCH}"-signed*.hap \
    "$PWD/TallyIsle-HarmonyOS-${TARGET_ARCH}-signed-debug.hap" \
    "$PWD"/*-"${TARGET_ARCH}"-signed*.hap \
    "$HOME/Downloads/TallyIsle-HarmonyOS-${TARGET_ARCH}-signed-debug.hap" \
    "$HOME/Downloads"/*-"${TARGET_ARCH}"-signed*.hap \
    "$SCRIPT_DIR/TallyIsle-HarmonyOS-${TARGET_ARCH}-unsigned.hap" \
    "$PWD/TallyIsle-HarmonyOS-${TARGET_ARCH}-unsigned.hap" \
    "$HOME/Downloads/TallyIsle-HarmonyOS-${TARGET_ARCH}-unsigned.hap" \
    "$SCRIPT_DIR"/*.hap \
    "$PWD"/*.hap; do
    if [[ -f "$candidate" ]]; then
      HAP_FILE="$candidate"
      break
    fi
  done
  shopt -u nullglob
fi

if [[ -z "$HAP_FILE" || ! -f "$HAP_FILE" ]]; then
  echo "[错误] 未找到 .hap 安装包。"
  echo "用法: bash $0 /path/to/TallyIsle-HarmonyOS-arm64-signed-debug.hap"
  echo "（x86_64 模拟器/设备请使用 \`TallyIsle-HarmonyOS-x64-signed-debug.hap\`）"
  exit 1
fi

if [[ "$HAP_FILE" == *"unsigned"* ]]; then
  echo "[警告] 检测到未签名安装包: $HAP_FILE"
  echo "鸿蒙真机无法直接安装未签名包（会报错 9568320）。"
  echo "请使用对应架构的签名包：\`TallyIsle-HarmonyOS-${TARGET_ARCH}-signed-debug.hap\`（ARM64 真机用 \`TallyIsle-HarmonyOS-arm64-signed-debug.hap\`，x86_64 模拟器/设备用 \`TallyIsle-HarmonyOS-x64-signed-debug.hap\`）！"
  echo ""
fi

echo "[4/4] 准备安装包: $HAP_FILE"
echo "正在安装帐屿到设备，请稍候..."
"$HDC_CMD" install -r "$HAP_FILE"
echo ""
echo "========================================================"
echo "  安装完成！现在可以在鸿蒙设备桌面上打开「帐屿」体验了。"
echo "========================================================"
