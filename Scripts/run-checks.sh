#!/bin/bash
# 运行 TileKit 自检（本机未安装 Xcode，没有 XCTest，因此使用自带断言程序）。
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
swift build -c debug --product TileKitCheck "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"
BIN="$(swift build -c debug --product TileKitCheck --show-bin-path "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}")/TileKitCheck"

if [ "$#" -ge 1 ] && [ -n "$1" ]; then
    exec "$BIN" "$1"
else
    exec "$BIN"
fi
