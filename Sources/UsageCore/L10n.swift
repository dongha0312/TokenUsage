import Foundation

/// 한국어·영어 문자열. 시스템 언어를 따른다.
///
/// `.strings` 번들 대신 코드로 둔 이유: SwiftPM 실행 파일을 직접 앱 번들로 조립하는 구조라
/// 리소스 번들을 끼우면 빌드가 복잡해진다. 문자열이 수십 개뿐이라 테이블 하나로 충분하다.
public enum L10n {
    /// 시스템이 한국어면 true. 테스트에서 덮어쓸 수 있게 열어둔다.
    public static var isKorean: Bool = {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("ko")
    }()

    static func pick(_ ko: String, _ en: String) -> String { isKorean ? ko : en }

    // MARK: - 창 라벨

    public static func label(for kind: WindowKind) -> String {
        switch kind {
        case .session(let hours):
            guard let hours else { return pick("현재 한도", "Current limit") }
            return pick("\(hours)시간 한도", "\(hours)-hour limit")
        case .weekly:
            return pick("주간 한도", "Weekly limit")
        case .weeklyAllModels:
            return pick("주간 · 모든 모델", "Weekly · all models")
        case .weeklyScoped(let model):
            return pick("주간 · \(model)", "Weekly · \(model)")
        case .other(let raw):
            return raw
        }
    }

    // MARK: - 시간

    public static func days(_ n: Int) -> String { pick("\(n)일", "\(n)d") }
    public static func hours(_ n: Int) -> String { pick("\(n)시간", "\(n)h") }
    public static func minutes(_ n: Int) -> String { pick("\(n)분", "\(n)m") }

    public static func resetsIn(head: String, time: String) -> String {
        pick("\(head) · \(time) 후 초기화", "\(head) · resets in \(time)")
    }

    public static var updatedJustNow: String { pick("방금 업데이트됨", "updated just now") }
    public static func updatedAgo(_ time: String) -> String {
        pick("\(time) 전에 업데이트됨", "updated \(time) ago")
    }

    // MARK: - 상태 문구

    public static func loginNeeded(_ host: String) -> String {
        pick("\(host) 로그인 필요", "sign in to \(host)")
    }
    public static var showingLocal: String { pick("로컬 값 표시 중", "showing local data") }
    public static var fetchFailed: String { pick("웹 조회 실패", "fetch failed") }
    public static var pageChanged: String {
        pick("수치를 못 읽음 — 페이지 구조가 바뀐 듯", "couldn't read values — page layout may have changed")
    }
    public static func pageUnreadable(_ host: String) -> String {
        pick("페이지를 못 읽음 · \(host)", "couldn't load page · \(host)")
    }
    public static var noUsageCache: String {
        pick("사용량 캐시 없음 — Claude Code에서 /usage 실행",
             "no usage cache — run /usage in Claude Code")
    }
    public static var configUnreadable: String {
        pick("~/.claude.json 을 읽지 못함", "couldn't read ~/.claude.json")
    }
    public static var noSessionLogs: String { pick("세션 로그 없음", "no session logs") }
    public static var noUsageRecord: String { pick("사용량 기록 없음", "no usage records") }

    // MARK: - 업데이트

    public static func downloadVersion(_ version: String) -> String {
        pick("새 버전 \(version) 받기", "Download version \(version)")
    }
    public static func updateTitle(_ version: String) -> String {
        pick("TokenUsage \(version) 출시", "TokenUsage \(version) is available")
    }
    public static var updateBody: String {
        pick("메뉴바 패널에서 받을 수 있습니다.", "Download it from the menu bar panel.")
    }

    // MARK: - UI

    public static var refresh: String { pick("새로 고침", "Refresh") }
    public static var quit: String { pick("종료", "Quit") }
    public static var launchAtLogin: String { pick("로그인 시 자동 실행", "Launch at login") }
    public static var approveInSettings: String {
        pick("시스템 설정에서 승인하기", "Approve in System Settings")
    }
    public static var signIn: String { pick("로그인", "Sign in") }
    public static var liveSignIn: String { pick("실시간 로그인:", "Live data — sign in:") }
    public static var refreshing: String { pick("갱신 중", "Refreshing") }
    public static func checking(_ name: String) -> String {
        pick("\(name) 확인 중", "Checking \(name)")
    }
    public static var openUsagePage: String { pick("사용량 페이지 열기", "Open usage page") }
    public static var menuBarStyle: String { pick("메뉴바에 표시할 것", "Show in the menu bar") }
    public static var styleUrgentHint: String {
        pick("한도에 가장 가까운 하나", "just the one closest to its limit")
    }
    public static var styleAllHint: String {
        pick("세 서비스의 남은 비율", "what's left on all three")
    }
    /// 메뉴바 숫자가 남은 쪽이라는 표시. 1.0 은 같은 자리에 사용량을 띄웠으므로
    /// 숫자만 두면 기존 사용자가 거꾸로 읽는다.
    public static func left(_ percent: String) -> String {
        pick("\(percent) 남음", "\(percent) left")
    }
    public static var refreshEvery: String { pick("갱신 주기", "Refresh every") }
    public static var refreshHint: String {
        pick("벤더 페이지를 실제로 여는 작업입니다", "each refresh actually loads the vendor pages")
    }
    public static var notifyNearLimit: String { pick("한도 임박 시 알림", "Notify when near limit") }
    /// macOS 가 이 번들을 알림 대상으로 인정하지 않을 때. 실측한 원인은 두 가지였다:
    /// 손으로 조립한 번들(Xcode 빌드가 아님), 그리고 실패 이력이 각인된 번들 ID.
    public static var notificationsUnavailable: String {
        pick("이 빌드에서는 알림을 쓸 수 없습니다 (Xcode 빌드 필요)",
             "Notifications unavailable in this build (needs an Xcode build)")
    }
    public static var notificationsOnTitle: String {
        pick("알림을 켰습니다", "Notifications on")
    }
    public static var notificationsOnBody: String {
        pick("한도의 80%를 넘으면 알려드립니다.", "You'll be notified when a limit passes 80%.")
    }
    public static func nearLimitTitle(_ provider: String) -> String {
        pick("\(provider) 한도 임박", "\(provider) near limit")
    }
    public static func nearLimitBody(_ label: String, percent: Int, reset: String?) -> String {
        let head = pick("\(label) \(percent)% 사용", "\(label) at \(percent)%")
        guard let reset else { return head }
        return pick("\(head) · \(reset) 후 초기화", "\(head) · resets in \(reset)")
    }
}
