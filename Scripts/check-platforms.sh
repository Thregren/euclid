#!/bin/bash
# 验证共享核心与渲染模块，覆盖 macOS、iPhone/iPad 真机与 ARM64 模拟器。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-debug}"
BUILD_ROOT="${BUILD_ROOT:-.build}"
read -r -a EXTRA_FLAGS <<< "${SWIFT_BUILD_FLAGS:-}"

for PLATFORM in macosx iphoneos iphonesimulator; do
    case "$PLATFORM" in
        macosx) TRIPLE=arm64-apple-macosx14.0 ;;
        iphoneos) TRIPLE=arm64-apple-ios17.0 ;;
        iphonesimulator) TRIPLE=arm64-apple-ios17.0-simulator ;;
    esac
    SDK_PATH="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"
    echo "==> 共享模块：$TRIPLE"
    swift build --target TileRendering -c "$CONFIG" --triple "$TRIPLE" --sdk "$SDK_PATH" \
        --scratch-path "$BUILD_ROOT/platform-$PLATFORM-arm64" "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"
done
