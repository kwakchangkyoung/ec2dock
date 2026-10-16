#!/bin/bash
# 배포 파일을 만든다: EC2Dock.app → zip, dmg. 조건이 갖춰지면 공증(notarization)까지 한다.
#
# 환경 변수 (build-app.sh와 같음)
#   VERSION, BUILD_NUMBER, BUNDLE_ID, SIGN_IDENTITY
#   NOTARY_PROFILE  `xcrun notarytool store-credentials`로 저장한 키체인 프로필 이름.
#                   Developer ID 서명(SIGN_IDENTITY)과 함께 지정하면 dmg를 공증하고 스테이플한다.
#
# 결과: dist/EC2Dock-<버전>.zip, dist/EC2Dock-<버전>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
export VERSION SIGN_IDENTITY

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
ls -lh "$ZIP" "$DMG"
