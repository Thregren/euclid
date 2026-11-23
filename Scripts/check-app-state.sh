#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCTS="${1:-$ROOT/.build/out/Products/Debug}"
if [[ ! -f "$PRODUCTS/TileKit.o" ]]; then
    echo "Build TileKit first, then pass its Products/Debug directory to this script." >&2
    exit 2
fi
WORK="$(mktemp -d /tmp/euclid-app-state-check.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx14.0 \
    -module-cache-path "$WORK/module-cache" -I "$PRODUCTS" -I "$ROOT/Sources/CSQLite" \
    "$ROOT/Sources/EuclidApp/WorkspaceCredentials.swift" \
    "$ROOT/Sources/EuclidApp/WorkspaceSessionDisk.swift" \
    "$ROOT/Sources/EuclidApp/MeasurementPersistenceCoordinator.swift" \
    "$ROOT/Sources/EuclidApp/MeasurementArchive.swift" \
    "$ROOT/Tests/AppStateRegression.swift" "$PRODUCTS/TileKit.o" -o "$WORK/check-app-state"
"$WORK/check-app-state"
