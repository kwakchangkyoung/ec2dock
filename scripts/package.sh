#!/bin/bash
# 배포 파일을 만든다: EC2Dock.app → zip, dmg. 조건이 갖춰지면 공증(notarization)까지 한다.
#
# 환경 변수 (build-app.sh와 같음)
#   VERSION, BUILD_NUMBER, BUNDLE_ID, SIGN_IDENTITY
#   NOTARY_PROFILE  `xcrun notarytool store-credentials`로 저장한 키체인 프로필 이름.
#                   Developer ID 서명(SIGN_IDENTITY)과 함께 지정하면 dmg를 공증하고 스테이플한다.
#   DOWNLOAD_URL    자동 업데이트가 내려받을 zip 주소 (기본: GitHub 릴리스 v<버전>의 EC2Dock.zip)
#   RELEASE_NOTES   업데이트 창에 보여줄 변경 사항 마크다운 파일 (선택)
#
# 자동 업데이트 목록(appcast.xml)은 키체인의 Sparkle 서명 키로 zip과 목록을 서명해 만든다.
# 키가 없으면 appcast.xml을 만들지 않는다.
#
# 결과: dist/EC2Dock-<버전>.zip, dist/EC2Dock-<버전>.dmg, dist/appcast.xml
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/kwakchangkyoung/ec2dock/releases/download/v$VERSION/EC2Dock.zip}"
RELEASE_NOTES="${RELEASE_NOTES:-}"
export VERSION BUILD_NUMBER SIGN_IDENTITY

./scripts/build-app.sh

APP="dist/EC2Dock.app"
ZIP="dist/EC2Dock-$VERSION.zip"
DMG="dist/EC2Dock-$VERSION.dmg"

echo "==> zip: $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> dmg: $DMG"
rm -f "$DMG"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$APP" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "EC2Dock $VERSION" -srcfolder "$staging" -fs HFS+ -format UDZO "$DMG"
[ "$SIGN_IDENTITY" != "-" ] && codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
hdiutil verify -quiet "$DMG"

SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
APPCAST="dist/appcast.xml"
rm -f "$APPCAST"
if "$SPARKLE_BIN/generate_keys" -p >/dev/null 2>&1; then
    echo "==> 자동 업데이트 목록: $APPCAST"
    signature="$("$SPARKLE_BIN/sign_update" "$ZIP")"
    notes=""
    if [ -n "$RELEASE_NOTES" ]; then
        notes="<description sparkle:format=\"markdown\"><![CDATA[$(cat "$RELEASE_NOTES")]]></description>"
    fi
    cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>EC2Dock</title>
        <item>
            <title>EC2Dock $VERSION</title>
            <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <sparkle:fullReleaseNotesLink>https://github.com/kwakchangkyoung/ec2dock/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
            $notes
            <enclosure url="$DOWNLOAD_URL" type="application/octet-stream" $signature/>
        </item>
    </channel>
</rss>
XML
    # 목록 자체도 서명한다 (앱이 SURequireSignedFeed로 확인).
    "$SPARKLE_BIN/sign_update" "$APPCAST" >/dev/null
else
    echo "==> 자동 업데이트 목록 생략 (키체인에 Sparkle 서명 키 없음)"
fi

if [ -n "$NOTARY_PROFILE" ]; then
    if [ "$SIGN_IDENTITY" = "-" ]; then
        echo "공증에는 Developer ID 서명이 필요합니다. SIGN_IDENTITY를 지정하세요." >&2
        exit 1
    fi
    echo "==> 공증 제출 (완료까지 몇 분 걸릴 수 있음)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
else
    echo "==> 공증 생략 (NOTARY_PROFILE 미지정)"
    if [ "$SIGN_IDENTITY" = "-" ]; then
        echo "    ad-hoc 서명 파일입니다. 이 Mac에서 직접 쓰는 용도이며, 다른 Mac에 내려받아 열면 Gatekeeper가 막습니다."
    fi
fi

echo "완료:"
ls -lh "$ZIP" "$DMG" $([ -f "$APPCAST" ] && echo "$APPCAST")
