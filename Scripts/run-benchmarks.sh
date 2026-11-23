#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
read -r -a EXTRA_FLAGS <<< "${SWIFT_BUILD_FLAGS:-}"
swift build -c release --product TileKitBench --triple arm64-apple-macosx14.0 "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"
BIN="$(swift build -c release --product TileKitBench --triple arm64-apple-macosx14.0 --show-bin-path "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}")/TileKitBench"
exec "$BIN" "$@"
