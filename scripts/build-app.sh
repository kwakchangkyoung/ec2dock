#!/bin/bash
# EC2Dock.app 번들을 만든다: 릴리스 빌드 → 번들 구성 → 코드 서명 → 검증.
#
# 환경 변수
#   VERSION        표시 버전 (기본: 0.1.0)
#   BUILD_NUMBER   빌드 번호 (기본: git 커밋 수)
#   BUNDLE_ID      번들 ID (기본: io.github.kwakchangkyoung.ec2dock)
#   FEED_URL       자동 업데이트 목록(appcast.xml) 주소 (기본: GitHub 최신 릴리스)
#   SIGN_IDENTITY  서명 인증서 이름. 기본 "-"는 ad-hoc 서명(이 Mac에서만 쓰는 용도).
#                  예: "Developer ID Application: 이름 (TEAMID)"
#
# 결과: dist/EC2Dock.app
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="${BUNDLE_ID:-io.github.kwakchangkyoung.ec2dock}"
FEED_URL="${FEED_URL:-https://github.com/kwakchangkyoung/ec2dock/releases/latest/download/appcast.xml}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

APP="dist/EC2Dock.app"

echo "==> 릴리스 빌드 (버전 $VERSION, 빌드 $BUILD_NUMBER)"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> 번들 구성: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/EC2Dock" "$APP/Contents/MacOS/EC2Dock"
# 자동 업데이트 프레임워크. 실행 파일이 Contents/Frameworks에서 찾도록 경로를 더한다.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/EC2Dock"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM 리소스 번들이 생기면 함께 싣는다 (현재는 없음).
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    -e "s|__FEED_URL__|$FEED_URL|" Packaging/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> 코드 서명 (${SIGN_IDENTITY/-/ad-hoc})"
ENTITLEMENTS="Packaging/EC2Dock.entitlements"
if [ "$SIGN_IDENTITY" = "-" ]; then
    # ad-hoc 서명에는 팀 ID가 없어 Hardened Runtime의 라이브러리 검증이 Sparkle.framework를 거부한다.
    # ad-hoc 빌드에서만 라이브러리 검증을 끈다 (Developer ID로 서명하면 같은 팀 ID라 필요 없다).
    ENTITLEMENTS="$(mktemp -t ec2dock-entitlements)"
    trap 'rm -f "$ENTITLEMENTS"' EXIT
    cp Packaging/EC2Dock.entitlements "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
fi
sign_args=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY")
# 공증에는 보안 타임스탬프가 필요하다. ad-hoc 서명에는 붙일 수 없다.
[ "$SIGN_IDENTITY" != "-" ] && sign_args+=(--timestamp)
# Sparkle은 안쪽부터 서명한다 (도우미 → 프레임워크 → 앱). 앱과 같은 서명이어야 실행 시 불러올 수 있다.
framework_args=(--force --options runtime --sign "$SIGN_IDENTITY")
[ "$SIGN_IDENTITY" != "-" ] && framework_args+=(--timestamp)
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${framework_args[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
codesign "${framework_args[@]}" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
codesign "${framework_args[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${framework_args[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${framework_args[@]}" "$SPARKLE"
codesign "${sign_args[@]}" "$APP"

echo "==> 서명 검증"
codesign --verify --strict --verbose=2 "$APP"

echo "완료: $APP"
