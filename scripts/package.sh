#!/bin/bash
# ============================================================
# disco 一键打包脚本
# 把 Rust daemon + SwiftUI App 合并成一个可双击运行的 disco.app
#
# 用法:
#   ./scripts/package.sh           # 打包（release）
#   ./scripts/package.sh --debug   # 打包（debug，更快但体积大）
#
# 产物: dist/disco.app
#
# 说明: daemon 的编译和打包由 Xcode 工程内置的
# "Build Rust Daemon" 脚本阶段自动完成（拷入 Contents/Resources），
# 本脚本只负责构建、签名和输出。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="disco"
MODE="${1:-release}"

if [ "$MODE" = "--debug" ]; then
    CONFIGURATION="Debug"
else
    CONFIGURATION="Release"
fi

DIST="$ROOT/dist"
DERIVED="$DIST/.derived"

echo "==> [1/2] xcodebuild 构建 [${CONFIGURATION}]（自动编译 daemon 并打入 App）"
xcodebuild build \
    -project "$ROOT/disco.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    -quiet

APP="$DERIVED/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [ ! -d "$APP" ]; then
    echo "错误: 找不到构建产物 $APP" >&2
    exit 1
fi

if [ ! -f "$APP/Contents/Resources/disco-daemon" ]; then
    echo "错误: App 包内缺少 disco-daemon（检查工程里的 Build Rust Daemon 脚本阶段）" >&2
    exit 1
fi

echo "==> [2/2] ad-hoc 签名并输出到 $DIST/disco.app"
codesign --force --deep --sign - "$APP"   # ad-hoc 签名，本地可直接运行
rm -rf "$DIST/disco.app"
cp -R "$APP" "$DIST/disco.app"
rm -rf "$DERIVED"

echo ""
echo "✅ 打包完成: $DIST/disco.app（daemon 已内置）"
echo "   双击运行，或: open \"$DIST/disco.app\""
echo ""
echo "⚠️  首次启动 daemon 需要 API Key："
echo '   先执行 export OPENAI_API_KEY=sk-xxx && open "dist/disco.app" 配一次，'
echo "   之后配置会存入 SQLite，不再需要环境变量。"
