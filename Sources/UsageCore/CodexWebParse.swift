import Foundation

/// chatgpt.com/codex/cloud/settings/analytics#usage 페이지의 텍스트에서 수치를 뽑는다.
///
/// 로컬 세션 로그(`rate_limits`)만으로도 이 맥의 사용량은 정확하다 — 실제로 웹과 대조해
/// 같은 값이 나오는 걸 확인했다. 웹이 필요한 이유는 **다른 기기에서 쓴 사용량** 때문이다.
/// 로컬 로그에는 이 맥의 세션만 남는다.
///
/// 페이지에서 확인한 실제 모양 (퍼센트와 "남음"이 다른 줄에 있다):
///
///   5시간 사용 한도 / 100% / 남음
///   주간 사용 한도 / 55% / 남음 / 2026. 9. 19. 오후 9:57 초기화
///
/// 주의: 아래쪽 "사용량 세부 정보" 차트에도 `0%` `100%` 축 눈금이 있다.
/// "남음"이 바로 뒤에 오는 것만 한도로 본다.
public enum CodexWebParse {
    public static func isLoaded(_ text: String) -> Bool {
        text.contains("사용 한도") || text.localizedCaseInsensitiveContains("usage limit")
    }

    private static let remainingWords = ["남음", "left", "remaining"]
    private static let knownPlans = ["FREE", "PLUS", "PRO", "BUSINESS", "ENTERPRISE", "TEAM", "GO"]

    public static func plan(from text: String) -> String? {
        ClaudeWebParse.cleanLines(text).prefix(20).first { knownPlans.contains($0) }
    }

    static func kind(for label: String) -> WindowKind {
        let lowered = label.lowercased()
        if label.contains("5시간") || lowered.contains("5-hour") || lowered.contains("5 hour") {
            return .session(hours: 5)
        }
        if label.contains("주간") || lowered.contains("weekly") || lowered.contains("week") {
            return .weekly
        }
        return .other(label)
    }

    public static func windows(from text: String, now: Date = Date(),
                               calendar: Calendar = .current) -> [UsageWindow] {
        guard isLoaded(text) else { return [] }
        let lines = ClaudeWebParse.cleanLines(text)
        var result: [UsageWindow] = []

        for (i, line) in lines.enumerated() {
            guard i >= 1, i + 1 < lines.count,
                  let remaining = barePercent(line),
                  remainingWords.contains(where: { lines[i + 1].caseInsensitiveCompare($0) == .orderedSame })
            else { continue }

            // 페이지는 "남은 비율"로 보여준다. 앱 전체는 사용률 기준이라 뒤집는다.
            let used = 100 - remaining
            let resetLine = i + 2 < lines.count ? lines[i + 2] : ""
            result.append(UsageWindow(kind: kind(for: lines[i - 1]),
                                      usedPercent: used,
                                      resetsAt: parseReset(resetLine, now: now, calendar: calendar)))
        }
        return result
    }

    /// "100%" 처럼 퍼센트만 있는 줄. "100% 남음" 같이 붙어 오는 경우도 받는다.
    static func barePercent(_ line: String) -> Double? {
        let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*%$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r = Range(m.range(at: 1), in: line) else { return nil }
        return Double(line[r])
    }

    /// "2026. 9. 19. 오후 9:57 초기화"
    public static func parseReset(_ line: String, now: Date, calendar: Calendar) -> Date? {
        guard line.contains("초기화") || line.localizedCaseInsensitiveContains("reset") else { return nil }
        let pattern = #"(\d{4})\.\s*(\d{1,2})\.\s*(\d{1,2})\.\s*(오전|오후)?\s*(\d{1,2}):(\d{2})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }

        func part(_ i: Int) -> String? {
            Range(m.range(at: i), in: line).map { String(line[$0]) }
        }
        guard let year = part(1).flatMap(Int.init),
              let month = part(2).flatMap(Int.init),
              let day = part(3).flatMap(Int.init),
              var hour = part(5).flatMap(Int.init),
              let minute = part(6).flatMap(Int.init) else { return nil }

        let marker = part(4) ?? ""
        if marker == "오후", hour < 12 { hour += 12 }
        if marker == "오전", hour == 12 { hour = 0 }

        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute))
    }
}
