#!/bin/sh
# TokenUsage 빌드.
#
# 두 가지 경로가 있다.
#
#  1. Xcode 프로젝트 (기본) — 알림을 쓰려면 이쪽이어야 한다.
#     손으로 조립한 번들은 macOS가 알림 대상 앱으로 인정하지 않는다.
#  2. SwiftPM 직접 조립 (NO_XCODE=1) — Xcode 없이 빌드할 때. 알림만 빠지고 나머지는 같다.
#
# 서명은 Developer ID > Apple Distribution > Apple Development 순으로 찾고,
# 없으면 ad-hoc 으로 떨어진다. SIGN_ID 로 직접 지정할 수 있다.
set -e
cd "$(dirname "$0")"

APP_NAME="TokenUsage"
BUNDLE_ID="io.github.dongha0312.tokenusage"
CONFIG="${CONFIG:-Release}"

find_identity() {
    [ -n "${SIGN_ID:-}" ] && { echo "$SIGN_ID"; return; }
    IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
    for PREFIX in "Developer ID Application" "Apple Distribution" "Apple Development"; do
        FOUND=$(printf '%s\n' "$IDENTITIES" \
            | awk -F\" -v p="$PREFIX" 'index($2, p) == 1 {print $2; exit}')
        [ -n "$FOUND" ] && { echo "$FOUND"; return; }
    done
    echo "-"
}

if [ "${NO_XCODE:-0}" = "1" ] || [ ! -d "$APP_NAME.xcodeproj" ]; then
    # --- SwiftPM 경로 ---
    swift build -c "$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')"
    BIN="$(swift build -c "$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')" --show-bin-path)/$APP_NAME"
    APP="build/$APP_NAME.app"
    rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
    cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
    sed "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$BUNDLE_ID|" Xcode/Info.plist > "$APP/Contents/Info.plist"
    mkdir -p "$APP/Contents/Resources"
    [ -f Xcode/AppIcon.icns ] || swift Xcode/make-icon.swift >/dev/null 2>&1 \
        && iconutil -c icns Xcode/AppIcon.iconset -o Xcode/AppIcon.icns 2>/dev/null || true
    cp Xcode/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true

    SIGN_ID=$(find_identity)
    codesign --force --sign "$SIGN_ID" --options runtime "$APP" 2>/dev/null \
        || codesign --force --sign "$SIGN_ID" "$APP" 2>/dev/null \
        || { codesign --force --sign - "$APP" 2>/dev/null || true; SIGN_ID="-"; }
    echo "빌드: SwiftPM (알림 사용 불가 — Xcode 경로를 쓰세요)"
else
    # --- Xcode 경로 (기본) ---
    #
    # 팀 ID는 설치된 인증서 이름 끝의 "(TEAMID)" 에서 뽑는다.
    # 포크한 사람이 파일을 고치지 않아도 자기 인증서로 빌드되게 하려는 것이다.
    # TEAM_ID 환경변수로 직접 줄 수도 있다.
    SIGN_ID=$(find_identity)
    if [ -z "${TEAM_ID:-}" ] && [ "$SIGN_ID" != "-" ]; then
        TEAM_ID=$(printf '%s' "$SIGN_ID" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')
    fi

    if [ -n "${TEAM_ID:-}" ]; then
        xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
            -configuration "$CONFIG" -derivedDataPath .xcbuild \
            TOKENUSAGE_TEAM_ID="$TEAM_ID" build \
            | grep -E "error:|BUILD" || true
    else
        # 인증서가 없으면 서명 없이 빌드하고 ad-hoc 으로 붙인다. 알림만 못 쓴다.
        xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
            -configuration "$CONFIG" -derivedDataPath .xcbuild \
            CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
            CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build \
            | grep -E "error:|BUILD" || true
    fi
    APP=".xcbuild/Build/Products/$CONFIG/$APP_NAME.app"
    [ -d "$APP" ] || { echo "빌드 실패: $APP 없음"; exit 1; }
    [ -n "${TEAM_ID:-}" ] || codesign --force --sign - "$APP" 2>/dev/null || true
    SIGN_ID=$(codesign -dvv "$APP" 2>&1 | awk -F'Authority=' '/Authority=/{print $2; exit}')
    echo "빌드: Xcode${TEAM_ID:+ (팀 $TEAM_ID)}"
fi

echo "서명: ${SIGN_ID:-알 수 없음}"
echo "완료: $APP"

if [ "$1" = "--install" ]; then
    DEST="/Applications/$APP_NAME.app"
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "설치: $DEST"
    open "$DEST"
fi
