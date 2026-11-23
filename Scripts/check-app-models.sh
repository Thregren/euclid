#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCTS="${1:-$ROOT/.build/out/Products/Debug}"
if [[ ! -f "$PRODUCTS/TileKit.o" || ! -f "$PRODUCTS/TileRendering.o" ]]; then
    echo "Build TileRendering first, then pass its Products/Debug directory to this script." >&2
    exit 2
fi
WORK="$(mktemp -d /tmp/euclid-app-model-check.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
DOMAIN="com.euclid.regression.$(basename "$WORK")"
BUNDLE="$WORK/ModelChecks.app"
mkdir -p "$BUNDLE/Contents/MacOS"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$DOMAIN</string><key>CFBundleExecutable</key><string>check-app-models</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(rg --files "$ROOT/Sources/EuclidApp" -g '*.swift' -g '!EuclidApp.swift')
xcrun swiftc -disable-sandbox -whole-module-optimization -Onone -parse-as-library -swift-version 6 -package-name Euclid -target arm64-apple-macosx14.0 \
    -module-cache-path "$WORK/module-cache" -I "$PRODUCTS" -I "$ROOT/Sources/CSQLite" \
    "${SOURCES[@]}" "$ROOT/Tests/AppModelRegression.swift" \
    "$PRODUCTS/TileKit.o" "$PRODUCTS/TileRendering.o" -o "$BUNDLE/Contents/MacOS/check-app-models"
"$BUNDLE/Contents/MacOS/check-app-models"
