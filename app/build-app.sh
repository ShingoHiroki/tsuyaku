#!/bin/bash
# GUI 試作版をビルドし、Info.plist つきの .app にまとめて署名する（アドホック署名）
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release

APP="build/Tsuyaku.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tsuyaku "$APP/Contents/MacOS/"
# SwiftPM が作るリソース（依存ライブラリの分）も同梱する
find .build/release -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;
cp Info.plist "$APP/Contents/"
# アイコン（元の絵は Icon/AppIcon.svg。作り直すときは Icon/make-icon.sh）
cp Icon/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
echo "作成: $(pwd)/$APP"
