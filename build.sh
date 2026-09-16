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

# 아이콘은 두 경로 모두의 빌드 입력이다. Xcode 프로젝트가 리소스로 참조하므로
# 없으면 xcodebuild 자체가 실패한다. 커밋돼 있지만, 지운 경우를 대비해 여기서 되살린다.
#
# 주의: `[ -f x ] || A && B` 는 `([ -f x ] || A) && B` 로 묶여서 B 가 항상 돌아간다.
# ||, && 는 우선순위가 같고 왼쪽 결합이다. 그래서 if 문으로 명시한다.
if [ ! -f Xcode/AppIcon.icns ]; then
    echo "아이콘 생성 중..."
    swift Xcode/make-icon.swift
    iconutil -c icns Xcode/AppIcon.iconset -o Xcode/AppIcon.icns
fi

if [ "${NO_XCODE:-0}" = "1" ] || [ ! -d "$APP_NAME.xcodeproj" ]; then
    # --- SwiftPM 경로 ---
    swift build -c "$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')"
    BIN="$(swift build -c "$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')" --show-bin-path)/$APP_NAME"
    APP="build/$APP_NAME.app"
    rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
    cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
    sed "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$BUNDLE_ID|" Xcode/Info.plist > "$APP/Contents/Info.plist"
    mkdir -p "$APP/Contents/Resources"
    cp Xcode/AppIcon.icns "$APP/Contents/Resources/" || echo "경고: 아이콘 복사 실패"

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

    APP=".xcbuild/Build/Products/$CONFIG/$APP_NAME.app"
    LOG=$(mktemp)

    # 낡은 산출물을 먼저 치운다. 안 그러면 빌드가 실패해도 지난번 앱이 남아 있어
    # "설치 완료" 가 찍히고, 낡은 바이너리를 설치하게 된다. 실제로 그렇게 당했다.
    rm -rf "$APP"

    # 파이프로 넘기면 xcodebuild 의 종료 코드가 사라진다($? 는 파이프 끝의 것이다).
    # 로그로 받아서 종료 코드를 직접 본다.
    if [ -n "${TEAM_ID:-}" ]; then
        xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
            -configuration "$CONFIG" -derivedDataPath .xcbuild \
            TOKENUSAGE_TEAM_ID="$TEAM_ID" build > "$LOG" 2>&1
    else
        # 인증서가 없으면 서명 없이 빌드하고 ad-hoc 으로 붙인다. 알림만 못 쓴다.
        xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
            -configuration "$CONFIG" -derivedDataPath .xcbuild \
            CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
            CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build > "$LOG" 2>&1
    fi
    STATUS=$?

    if [ $STATUS -ne 0 ] || [ ! -d "$APP" ]; then
        echo "빌드 실패:"
        grep -E "error:|error " "$LOG" | head -20
        [ -s "$LOG" ] || echo "  (로그 없음)"
        echo "  전체 로그: $LOG"
        exit 1
    fi
    rm -f "$LOG"

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
