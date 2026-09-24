#!/bin/bash
# 编译并打包成可双击运行的 .app（无需 Xcode）。
set -euo pipefail

cd "$(dirname "$0")/.."

# 当前开发者目录不可用时（例如 Xcode 许可尚未接受）自动回退到 CommandLineTools。
if ! swift --version >/dev/null 2>&1; then
    if [ -d /Library/Developer/CommandLineTools ]; then
        export DEVELOPER_DIR=/Library/Developer/CommandLineTools
        echo "提示：当前工具链不可用（可能是 Xcode 许可未接受），已回退到 CommandLineTools。"
        echo "      若想用 Xcode 工具链（可打通用二进制），先执行：sudo xcodebuild -license accept"
    else
        echo "错误：找不到可用的 Swift 工具链。" >&2
        exit 1
    fi
fi

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

echo "==> 裁剪调试信息"
# 调试信息里会记下本机构建路径（/Users/<用户名>/…、.build/out/…），
# 发布包不该带上这些信息；strip -S 只去掉 DWARF，不影响运行。
if ! strip -S "$APP/Contents/MacOS/$EXECUTABLE" 2>/dev/null; then
    echo "    提示：strip 未成功，发布包可能仍带有本机构建路径。"
fi
if strings -a "$APP/Contents/MacOS/$EXECUTABLE" | grep -q "/Users/"; then
    echo "    警告：可执行文件里仍能匹配到 /Users/ 路径，请检查后再发布。"
else
    echo "    未发现本机构建路径残留"
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
