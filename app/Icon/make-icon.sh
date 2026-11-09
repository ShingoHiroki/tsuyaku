#!/bin/bash
# app/Icon/AppIcon.svg から、アプリのアイコン（app/Icon/AppIcon.icns）を作り直す
# 使い方（リポジトリのルートで）：bash app/Icon/make-icon.sh
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/AppIcon.iconset"
mkdir "$SET"

# macOS のアイコンに必要な10種類（16〜512 と、それぞれの2倍の解像度）
for size in 16 32 128 256 512; do
    swift render.swift AppIcon.svg "$SET/icon_${size}x${size}.png" "$size"
    swift render.swift AppIcon.svg "$SET/icon_${size}x${size}@2x.png" "$((size * 2))"
done

iconutil -c icns "$SET" -o AppIcon.icns
echo "作成: $(pwd)/AppIcon.icns"
