#!/bin/bash
# 编译并打包成可双击运行的 .app（无需 Xcode）。
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
PRODUCT="Euclid"
EXECUTABLE="Euclid"
APP_NAME="尺规"
DIST="${DIST:-dist}"
APP="$DIST/$APP_NAME.app"

# 需要时可通过 SWIFT_BUILD_FLAGS 追加参数，例如 --disable-sandbox
read -r -a EXTRA_FLAGS <<< "${SWIFT_BUILD_FLAGS:-}"

echo "==> 编译（${CONFIG}）"
swift build -c "$CONFIG" --product "$PRODUCT" "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"

BIN_PATH="$(swift build -c "$CONFIG" --product "$PRODUCT" --show-bin-path "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}")"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/$PRODUCT" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> ad-hoc 签名"
# 清理扩展属性：FinderInfo / 文件提供程序属性会让 codesign 拒绝签名。
find "$APP" -name ".DS_Store" -delete 2>/dev/null || true
xattr -r -d com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -r -d "com.apple.fileprovider.fpfs#P" "$APP" 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true
if ! codesign --force --deep --sign - "$APP" 2>/dev/null; then
    echo "    提示：签名未成功（多为输出目录受 iCloud 文件提供程序管理所致）。"
    echo "    本机仍可运行；若要产出可分发的包，可指定输出目录，例如："
    echo "      DIST=/tmp/euclid-dist ./Scripts/build-app.sh"
fi

touch "$APP"
echo "==> 完成：$APP"
