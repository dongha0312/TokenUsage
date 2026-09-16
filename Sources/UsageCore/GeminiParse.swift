import Foundation

/// gemini.google.com/usage 페이지의 텍스트에서 수치를 뽑는다.
///
/// 뒤에는 batchexecute RPC가 있지만 직접 부르지 않는다. 세션ID·빌드라벨·at 토큰이 필요하고
/// rpcid(jSf9Qc 등)가 난독화된 심볼명이라 Google이 빌드할 때마다 바뀐다.
/// 페이지를 그대로 띄워 읽으면 그 복잡함을 전부 페이지가 처리해준다.
///
/// 페이지에서 확인한 실제 모양 (섹션마다 %와 Resets 순서가 다르다):
///
///   Current usage / 0% used / Resets at 7:00 PM
///   Weekly limit  / Resets Sep 22 at 2:00 PM / 0% used
public enum GeminiParse {
    /// 이 문구가 없으면 사용량 페이지가 아니다 (미로그인이거나 아직 렌더 전).
    public static let sentinel = "Usage limits"

    public static func isLoaded(_ text: String) -> Bool { text.contains(sentinel) }

    /// "Usage limits" 바로 뒤에 플랜 배지가 온다 (PRO / ULTRA 등).
    public static func plan(from text: String) -> String? {
        guard let range = text.range(of: sentinel) else { return nil }
        let after = text[range.upperBound...].prefix(40)
        return after.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.count <= 12 && $0 == $0.uppercased() && $0.first!.isLetter }
    }

    public static func windows(from text: String, now: Date = Date(),
                               calendar: Calendar = .current) -> [UsageWindow] {
        guard isLoaded(text) else { return [] }
        // "Weekly limit"을 기준으로 두 섹션으로 자른다. 섹션 안에서는 순서를 따지지 않는다.
        let parts = text.components(separatedBy: "Weekly limit")
        var result: [UsageWindow] = []
        if let current = parts.first,
           let w = window(kind: .session(hours: nil), section: current, now: now, calendar: calendar) {
            result.append(w)
        }
        if parts.count > 1,
           let w = window(kind: .weekly, section: parts[1], now: now, calendar: calendar) {
            result.append(w)
        }
        return result
    }

    static func window(kind: WindowKind, section: String, now: Date, calendar: Calendar) -> UsageWindow? {
        guard let used = firstMatch(#"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#, in: section),
              let percent = Double(used) else { return nil }
        let reset = firstMatch(#"Resets\s+(?:at\s+)?([^\n]+)"#, in: section)
            .flatMap { parseReset($0, now: now, calendar: calendar) }
        return UsageWindow(kind: kind, usedPercent: percent, resetsAt: reset)
    }

    /// "7:00 PM" 또는 "Sep 22 at 2:00 PM" 두 가지 모양을 받는다.
    public static func parseReset(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone

        // 시각만 있으면 오늘, 이미 지났으면 내일.
        f.dateFormat = "h:mm a"
        if let t = f.date(from: s) {
            let hm = calendar.dateComponents([.hour, .minute], from: t)
            guard var d = calendar.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0,
                                        second: 0, of: now) else { return nil }
            if d <= now { d = calendar.date(byAdding: .day, value: 1, to: d) ?? d }
            return d
        }

        // 날짜가 붙어 있으면 연도가 없으므로 올해로 두고, 과거로 계산되면 내년으로 넘긴다.
        f.dateFormat = "MMM d 'at' h:mm a"
        guard let t = f.date(from: s) else { return nil }
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: t)
        var comps = DateComponents(year: calendar.component(.year, from: now),
                                   month: c.month, day: c.day, hour: c.hour, minute: c.minute)
        guard var d = calendar.date(from: comps) else { return nil }
        if d < now.addingTimeInterval(-86400) {
            comps.year = (comps.year ?? 0) + 1
            d = calendar.date(from: comps) ?? d
        }
        return d
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
