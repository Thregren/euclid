#!/bin/bash
# 编译并打包成可双击运行的 .app（无需 Xcode）。
set -euo pipefail

cd "$(dirname "$0")/.."

# 当前开发者目录不可用时（例如 Xcode 许可尚未接受）自动回退到 CommandLineTools。
if ! swift --version >/dev/null 2>&1; then
    if [ -d /Library/Developer/CommandLineTools ]; then
        export DEVELOPER_DIR=/Library/Developer/CommandLineTools
        echo "提示：当前工具链不可用（可能是 Xcode 许可未接受），已回退到 CommandLineTools。"
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

BUILD_ARGS=(-c "$CONFIG" --product "$PRODUCT" --triple arm64-apple-macosx14.0)
if [ "${#EXTRA_FLAGS[@]}" -gt 0 ]; then
    BUILD_ARGS+=("${EXTRA_FLAGS[@]}")
fi

echo "==> 编译（${CONFIG}, ARM64）"
swift build "${BUILD_ARGS[@]}"
swift build -c "$CONFIG" --product tiletools --triple arm64-apple-macosx14.0 "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"

BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
if [ "$(lipo -archs "$BIN_PATH/$PRODUCT")" != "arm64" ]; then
    echo "错误：构建产物必须只含 arm64 架构。" >&2
    exit 1
fi

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/$PRODUCT" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$BIN_PATH/tiletools" "$APP/Contents/MacOS/tiletools"
cp "$BIN_PATH/tiletools" "$DIST/tiletools-arm64"
strip -S "$APP/Contents/MacOS/tiletools" "$DIST/tiletools-arm64"
codesign --force --sign - "$DIST/tiletools-arm64"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp LICENSE "$DIST/LICENSE"
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
xattr -r -d com.apple.provenance "$APP" 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true

# 输出目录被文件提供程序（iCloud 文稿同步、网盘客户端等）管理时，属性会被异步加回来，
# 让 codesign 报「resource fork, Finder information, or similar detritus not allowed」。
# 清一次不行就再清一次重签；两次都失败就直接报错退出 ——
# 签名失败的 .app 一启动就被 dyld 杀掉（崩溃报告里只有 dyld 的帧），
# 那种包发出去别人打不开，宁可让它打不出来。
signed=0
for attempt in 1 2; do
    if codesign --force --deep --sign - "$APP" 2>/dev/null; then
        signed=1
        break
    fi
    xattr -cr "$APP" 2>/dev/null || true
done
if [ "$signed" != "1" ]; then
    echo "错误：ad-hoc 签名失败，产物不可用（启动会被系统直接终止）。" >&2
    echo "      多半是输出目录受文件提供程序（iCloud 文稿 / 网盘）管理，扩展属性清不掉。" >&2
    echo "      换一个不受管理的目录再打包，例如：" >&2
    echo "        DIST=/tmp/euclid-dist ./Scripts/build-app.sh" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP"
codesign --verify --strict "$DIST/tiletools-arm64"

touch "$APP"
echo "==> 完成：$APP"
