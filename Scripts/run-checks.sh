#!/bin/bash
# 运行 TileKit 自检（本机未安装 Xcode，没有 XCTest，因此使用自带断言程序）。
set -euo pipefail

cd "$(dirname "$0")/.."

read -r -a EXTRA_FLAGS <<< "${SWIFT_BUILD_FLAGS:-}"
swift build -c debug --product TileKitCheck "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"
BIN="$(swift build -c debug --product TileKitCheck --show-bin-path "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}")/TileKitCheck"

if [ "$#" -ge 1 ] && [ -n "$1" ]; then
    exec "$BIN" "$1"
else
    exec "$BIN"
fi
