#!/bin/bash
# EC2Dock.app 번들을 만든다: 릴리스 빌드 → 번들 구성 → 코드 서명 → 검증.
#
# 환경 변수
#   VERSION        표시 버전 (기본: 0.1.0)
#   BUILD_NUMBER   빌드 번호 (기본: git 커밋 수)
#   BUNDLE_ID      번들 ID (기본: io.github.kwakchangkyoung.ec2dock)
#   SIGN_IDENTITY  서명 인증서 이름. 기본 "-"는 ad-hoc 서명(이 Mac에서만 쓰는 용도).
#                  예: "Developer ID Application: 이름 (TEAMID)"
#
# 결과: dist/EC2Dock.app
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="${BUNDLE_ID:-io.github.kwakchangkyoung.ec2dock}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

APP="dist/EC2Dock.app"

echo "==> 릴리스 빌드 (버전 $VERSION, 빌드 $BUILD_NUMBER)"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> 번들 구성: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/EC2Dock" "$APP/Contents/MacOS/EC2Dock"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM 리소스 번들이 생기면 함께 싣는다 (현재는 없음).
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    Packaging/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> 코드 서명 (${SIGN_IDENTITY/-/ad-hoc})"
sign_args=(--force --options runtime --entitlements Packaging/EC2Dock.entitlements --sign "$SIGN_IDENTITY")
# 공증에는 보안 타임스탬프가 필요하다. ad-hoc 서명에는 붙일 수 없다.
[ "$SIGN_IDENTITY" != "-" ] && sign_args+=(--timestamp)
codesign "${sign_args[@]}" "$APP"

echo "==> 서명 검증"
codesign --verify --strict --verbose=2 "$APP"

echo "완료: $APP"
