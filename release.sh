#!/bin/sh
#
# 배포본(.dmg) 만들기.
#
#   ./release.sh
#
# 받아서 Applications 로 끌어다 놓으면 끝나는 형태로 만든다. Xcode 를 깔라고 하는 대신
# 이걸 Releases 에 올리면 개발자가 아닌 사람도 쓸 수 있다.
#
# 공증(notarization)까지 하려면 Apple 계정 자격증명이 필요하다. 이 스크립트는 그걸
# 직접 받지 않는다 — 키체인에 한 번 저장해두면(아래 안내) 거기서 읽어 쓴다.
set -e
cd "$(dirname "$0")"

APP_NAME="TokenUsage"
VOLUME="$APP_NAME"
NOTARY_PROFILE="${NOTARY_PROFILE:-tokenusage-notary}"
OUT="dist"
DMG="$OUT/$APP_NAME.dmg"

# --- 1. Developer ID 로 서명된 빌드 -------------------------------------------
#
# 배포에는 Developer ID Application 이어야 한다. Apple Development 인증서는
# 내 기기에서 돌리는 용도라 공증을 통과하지 못한다.
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F\" '/Developer ID Application/{print $2; exit}')

if [ -z "$DEV_ID" ]; then
    cat <<'MSG'
Developer ID Application 인증서가 없습니다.

배포본은 서명이 없으면 다른 맥에서 Gatekeeper 에 막힙니다. 유료 Apple Developer
Program 회원이면 추가 비용 없이 만들 수 있습니다:

  Xcode → Settings → Accounts → 계정 선택 → Manage Certificates...
  → 왼쪽 아래 [+] → Developer ID Application

만들고 다시 실행하세요. 서명 없이 그냥 써볼 거면 ./build.sh --install 을 쓰면 됩니다.
MSG
    exit 1
fi

echo "서명 인증서: $DEV_ID"
TEAM_ID=$(printf '%s' "$DEV_ID" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')

rm -rf .xcbuild "$OUT"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -configuration Release -derivedDataPath .xcbuild \
    TOKENUSAGE_TEAM_ID="$TEAM_ID" build | grep -E "error:|BUILD" || true

APP=".xcbuild/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "빌드 실패"; exit 1; }

# 공증은 hardened runtime 과 보안 타임스탬프를 요구한다.
codesign --force --options runtime --timestamp --sign "$DEV_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# --- 2. 앱 공증 + 스테이플 ------------------------------------------------------
#
# DMG 에만 티켓을 붙이면 앱 자체에는 없다. 사용자가 앱을 Applications 로 복사한 뒤
# 오프라인이면 Gatekeeper 가 온라인 확인을 못 해 실행이 막히거나 늦어진다.
# 그래서 앱을 먼저 공증·스테이플하고, 그 앱으로 DMG 를 만든다.
notarize() {   # $1 = 제출할 파일
    if ! xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait; then
        echo "공증 실패: $1"
        exit 1
    fi
}

mkdir -p "$OUT"
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARIZE=1
    echo "앱 공증 중... (몇 분 걸립니다)"
    ditto -c -k --keepParent "$APP" "$OUT/app.zip"
    notarize "$OUT/app.zip"
    rm -f "$OUT/app.zip"
    xcrun stapler staple "$APP"
else
    NOTARIZE=0
fi

# --- 3. DMG 조립 --------------------------------------------------------------
#
# Applications 심볼릭 링크를 같이 넣어, 열었을 때 끌어다 놓기만 하면 되게 한다.
mkdir -p "$OUT/staging"
cp -R "$APP" "$OUT/staging/"
ln -s /Applications "$OUT/staging/Applications"

hdiutil create -volname "$VOLUME" -srcfolder "$OUT/staging" \
    -ov -format UDZO -quiet "$DMG"
rm -rf "$OUT/staging"

# DMG 자체도 서명한다. 안 하면 받는 쪽에서 경고가 뜬다.
codesign --force --sign "$DEV_ID" --timestamp "$DMG"
echo "생성: $DMG"

# --- 4. DMG 공증 --------------------------------------------------------------
if [ "$NOTARIZE" = "1" ]; then
    echo "DMG 공증 중..."
    notarize "$DMG"
    xcrun stapler staple "$DMG"

    echo "--- 검증 ---"
    xcrun stapler validate "$DMG"
    spctl -a -t open --context context:primary-signature -v "$DMG"
    echo "공증 완료: $DMG"
else
    cat <<MSG

DMG 는 만들어졌지만 공증은 건너뛰었습니다.
공증하지 않으면 받는 사람에게 "개발자를 확인할 수 없습니다" 경고가 뜹니다.

한 번만 자격증명을 저장하면 그 뒤로는 자동입니다:

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id <애플ID> --team-id $TEAM_ID --password <앱 암호>

앱 암호는 appleid.apple.com → 로그인 및 보안 → 앱 암호 에서 만듭니다.
계정 비밀번호가 아닙니다. 저장한 뒤 이 스크립트를 다시 실행하세요.
MSG
fi

echo
echo "배포:  gh release create v1.0 $DMG --title 'TokenUsage 1.0' --notes '...'"
