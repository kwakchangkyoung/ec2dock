#!/bin/bash
# Packaging/AppIcon.icns를 다시 만든다. 생성된 icns는 저장소에 포함되므로 아이콘을 바꿀 때만 실행한다.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

swift scripts/make-icon.swift "$work/icon-1024.png"

iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o Packaging/AppIcon.icns
echo "생성: Packaging/AppIcon.icns"
