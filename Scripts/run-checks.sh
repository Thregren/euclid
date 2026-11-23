#!/bin/bash
# 运行核心库与共享渲染器的 ARM64 自检。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! swift --version >/dev/null 2>&1; then
    if [ -d /Library/Developer/CommandLineTools ]; then
        export DEVELOPER_DIR=/Library/Developer/CommandLineTools
        echo "提示：当前工具链不可用（可能是 Xcode 许可未接受），已回退到 CommandLineTools。"
    else
        echo "错误：找不到可用的 Swift 工具链。" >&2
        exit 1
    fi
fi

read -r -a EXTRA_FLAGS <<< "${SWIFT_BUILD_FLAGS:-}"
swift build -c debug --product TileKitCheck --triple arm64-apple-macosx14.0 "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"
BIN="$(swift build -c debug --product TileKitCheck --triple arm64-apple-macosx14.0 --show-bin-path "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}")/TileKitCheck"

if [ "$#" -ge 1 ] && [ -n "$1" ]; then
    exec "$BIN" "$1"
else
    exec "$BIN"
fi
