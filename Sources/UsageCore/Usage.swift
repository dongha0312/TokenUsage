import Foundation

public enum Provider: String, CaseIterable, Sendable {
    case claude = "Claude"
    case codex = "Codex"
    case gemini = "Gemini"
}

/// 창의 종류. 파서는 벤더 페이지의 문구가 아니라 **의미**를 넘긴다.
///
/// 파서가 "5시간 한도" 같은 완성된 문자열을 만들면 그 언어에 갇힌다.
/// 벤더 페이지는 계정 언어를 따라가고, 앱 UI는 시스템 언어를 따라가야 하므로 둘을 분리한다.
public enum WindowKind: Sendable, Equatable, Hashable {
    /// 현재 진행 중인 짧은 창. 길이를 아는 벤더만 시간을 싣는다.
    /// Claude·Codex는 5시간이지만 Gemini는 길이를 공개하지 않으므로 nil이다.
    /// 여기에 5를 넣어두면 Gemini 창을 "5시간 한도"라고 거짓말하게 된다.
    case session(hours: Int?)
    /// 주간 한도. 모델 구분이 없는 벤더용.
    case weekly
    /// 주간 한도 중 "모든 모델" 몫. 모델별 한도가 따로 있는 벤더(Claude)에서만 쓴다.
    case weeklyAllModels
    /// 주간, 특정 모델 한정. 모델 이름은 벤더가 준 표기를 그대로 쓴다.
    case weeklyScoped(String)
    /// 알 수 없는 종류. 벤더 문구를 그대로 통과시킨다.
    case other(String)

    /// 지금 진행 중인 짧은 창인가. 메뉴바 기준을 고를 때 쓴다.
    public var isSession: Bool {
        if case .session = self { return true }
        return false
    }

    /// 정렬·중복 제거용 안정 키
    public var id: String {
        switch self {
        case .session(let h): return "session:\(h.map(String.init) ?? "-")"
        case .weekly: return "weekly"
        case .weeklyAllModels: return "weekly:all"
        case .weeklyScoped(let m): return "weekly:\(m)"
        case .other(let s): return "other:\(s)"
        }
    }
}

/// 한도 창 하나.
///
/// 비율은 **사용한 쪽**을 담는다. 세 벤더가 모두 "얼마나 썼는가"로 보고하므로
/// 뒤집지 않고 그대로 쓴다. 뒤집으면 벤더 화면과 대조할 때마다 헷갈린다.
public struct UsageWindow: Sendable, Equatable {
    public let kind: WindowKind
    /// 한도를 모르면 nil. 모르는 분모를 지어내지 않는다.
    public let usedPercent: Double?
    public let resetsAt: Date?

    public init(kind: WindowKind, usedPercent: Double?, resetsAt: Date?) {
        self.kind = kind
        self.usedPercent = usedPercent.map { min(max($0, 0), 100) }
        self.resetsAt = resetsAt
    }

    /// "3시간" · "3일" · "47분". 리셋 시각을 모르거나 이미 지났으면 nil.
    /// 주간 창을 "76:53"으로 찍으면 읽히지 않으므로 가장 큰 눈금 하나만 쓴다.
    public func timeToReset(now: Date = Date()) -> String? {
        guard let resetsAt, resetsAt > now else { return nil }
        let secs = Int(resetsAt.timeIntervalSince(now))
        if secs >= 86400 { return L10n.days(secs / 86400) }
        if secs >= 3600 { return L10n.hours(secs / 3600) }
        return L10n.minutes(max(secs / 60, 1))
    }

    /// "11% · 3시간 후 초기화" / "11% · resets in 3h"
    public func summary(now: Date = Date()) -> String {
        let head = usedPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        guard let t = timeToReset(now: now) else { return head }
        return L10n.resetsIn(head: head, time: t)
    }

    /// 시스템 언어로 번역된 라벨.
    public var label: String { L10n.label(for: kind) }

    /// 한도에 얼마나 가까운가. 색과 알림 판단에 쓴다.
    public var severity: Severity {
        switch usedPercent ?? 0 {
        case 95...: return .critical
        case 80...: return .warning
        default: return .normal
        }
    }

    public enum Severity: Sendable, Equatable { case normal, warning, critical }
}

public struct ProviderUsage: Sendable, Equatable {
    public let provider: Provider
    public let windows: [UsageWindow]
    /// 이 수치가 언제 기준인지. 벤더가 내려준 시점이지 우리가 읽은 시점이 아니다.
    public let updatedAt: Date?
    /// "MAX" · "PLUS" · "PRO" 같은 플랜 표기. 없으면 nil.
    public let plan: String?
    public let note: String?

    public init(provider: Provider, windows: [UsageWindow], updatedAt: Date?,
                plan: String? = nil, note: String? = nil) {
        self.provider = provider
        self.windows = windows
        self.updatedAt = updatedAt
        self.plan = plan
        self.note = note
    }

    /// 가장 많이 쓴 창. 비율을 모르는 창은 비교 대상이 아니다.
    public var mostUrgent: UsageWindow? {
        windows.compactMap { w in w.usedPercent.map { (w, $0) } }
               .max { $0.1 < $1.1 }?.0
    }

    public static func unavailable(_ provider: Provider, _ note: String, at: Date? = nil) -> ProviderUsage {
        ProviderUsage(provider: provider, windows: [], updatedAt: at, note: note)
    }
}

/// 여러 제공자 중 메뉴바에 올릴 하나를 고른다.
///
/// **세션 창을 기준으로 삼는다.** 지금 당장 나를 막는 건 세션 한도이고, 주간은 며칠 뒤 얘기다.
/// 주간을 같이 놓고 최대값을 고르면 "주간 45%" 가 "세션 2%" 를 가려서, 정작 지금 여유가
/// 많은 서비스가 제일 급한 것처럼 보인다.
///
/// 다만 주간이 실제로 위험해지면(경고 이상) 숨기면 안 되므로 그때만 후보에 넣는다.
public func mostUrgent(among usages: [ProviderUsage]) -> (ProviderUsage, UsageWindow)? {
    let all = usages.flatMap { usage in usage.windows.map { (usage, $0) } }
                    .filter { $0.1.usedPercent != nil }
    let sessions = all.filter { $0.1.kind.isSession }
    let urgentOthers = all.filter { !$0.1.kind.isSession && $0.1.severity != .normal }

    // 세션 창이 아예 없는 제공자만 있을 수도 있다. 그때는 전부를 후보로 둔다.
    let pool = sessions.isEmpty ? all : sessions + urgentOthers
    return pool.max { ($0.1.usedPercent ?? 0) < ($1.1.usedPercent ?? 0) }
}

/// 메뉴바 한 줄에 들어갈 텍스트. 아이콘은 호출하는 쪽이 붙인다.
public func menuBarText(for usages: [ProviderUsage], now: Date = Date()) -> String {
    guard let (_, window) = mostUrgent(among: usages),
          let used = window.usedPercent else { return "—" }
    let pct = Int(used.rounded())
    if let t = window.timeToReset(now: now) { return "\(pct)% · \(t)" }
    return "\(pct)%"
}

/// "14분 전에 업데이트됨" / "updated 14m ago"
public func updatedAgo(_ updatedAt: Date?, now: Date = Date()) -> String? {
    guard let updatedAt else { return nil }
    let secs = Int(now.timeIntervalSince(updatedAt))
    if secs < 60 { return L10n.updatedJustNow }
    if secs < 3600 { return L10n.updatedAgo(L10n.minutes(secs / 60)) }
    if secs < 86400 { return L10n.updatedAgo(L10n.hours(secs / 3600)) }
    return L10n.updatedAgo(L10n.days(secs / 86400))
}

/// 웹에서 읽은 창에 리셋 시각이 비었으면 로컬 기록에서 채운다.
///
/// 퍼센트는 숫자라 언어를 안 타지만 리셋 시각은 "2026. 9. 19. 오후 9:57" 처럼 지역 형식을 탄다.
/// 로컬 로그·캐시에는 같은 값이 epoch나 ISO로 들어 있으므로, 못 읽었을 때 그쪽을 쓴다.
/// 덕분에 날짜 형식 하나 때문에 기능 전체가 무너지지 않는다.
public func fillingMissingResets(_ windows: [UsageWindow],
                                 from local: [UsageWindow]) -> [UsageWindow] {
    guard !local.isEmpty else { return windows }
    let byKind = Dictionary(local.map { ($0.kind.id, $0) }, uniquingKeysWith: { a, _ in a })
    return windows.map { window in
        guard window.resetsAt == nil, let match = byKind[window.kind.id],
              let resetsAt = match.resetsAt else { return window }
        return UsageWindow(kind: window.kind, usedPercent: window.usedPercent, resetsAt: resetsAt)
    }
}
