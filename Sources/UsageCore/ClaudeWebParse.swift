import Foundation

/// claude.ai/settings/usage 페이지의 텍스트에서 수치를 뽑는다.
///
/// `~/.claude.json` 캐시는 `/usage` 를 돌려야만 갱신되므로 실시간이 아니다 (실측: 12분간 26회
/// 샘플링해도 안 움직였고, 설정 백업을 되짚으니 키 자체가 /usage 실행 순간 생겼다).
/// 이 페이지는 살아 있다 — 같은 시점에 웹은 14%, 캐시는 10%였다.
///
/// 페이지에서 확인한 실제 모양 (라벨 → 재설정 → 퍼센트, 세 줄 묶음):
///
///   현재 세션 / 오후 9:10에 재설정 / 14% 사용됨
///   이번 주 / (일요일) 오후 12:00에 재설정 / 5% 사용됨
///   이번 주 Fable / 별도 주간 한도 대상: Fable · (일요일) 오후 12:00에 재설정 / 0% 사용됨
public enum ClaudeWebParse {
    /// 이 문구가 없으면 사용량 화면이 아니다 (미로그인이거나 아직 렌더 전).
    public static func isLoaded(_ text: String) -> Bool {
        text.contains("사용됨") || text.localizedCaseInsensitiveContains("% used")
    }

    /// 페이지 라벨을 의미로 바꾼다. 문구를 그대로 들고 가면 그 언어에 갇힌다.
    static func kind(for label: String) -> WindowKind {
        switch label {
        case "현재 세션", "Current session": return .session(hours: 5)
        case "이번 주", "Current week": return .weeklyAllModels
        default:
            // "이번 주 Fable" / "Current week (Fable)" 같은 모델 한정 라벨
            if let model = label.split(separator: " ").last, label != String(model) {
                return .weeklyScoped(model.trimmingCharacters(in: CharacterSet(charactersIn: "()")))
            }
            return .other(label)
        }
    }

    public static func plan(from text: String) -> String? {
        // "사용량" 다음 줄에 "Max (5x)" 같은 플랜 표기가 온다.
        // 제목이 두 번 반복되므로(헤더 + 섹션명) 제목 자체는 건너뛴다.
        let titles: Set<String> = ["사용량", "Usage"]
        let lines = cleanLines(text)
        for (i, line) in lines.enumerated() where titles.contains(line) {
            guard i + 1 < lines.count else { continue }
            let candidate = lines[i + 1]
            guard !titles.contains(candidate),
                  candidate.count <= 20,
                  candidate.rangeOfCharacter(from: .letters) != nil,
                  !candidate.contains("사용") else { continue }
            return candidate
        }
        return nil
    }

    /// 빈 줄을 걸러낸 줄 목록. 다른 페이지 파서도 같이 쓴다.
    public static func cleanLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func windows(from text: String, now: Date = Date(),
                               calendar: Calendar = .current) -> [UsageWindow] {
        guard isLoaded(text) else { return [] }
        let lines = cleanLines(text)
        var result: [UsageWindow] = []

        // "N% 사용됨" 을 기준점으로 잡고 앞의 두 줄을 재설정·라벨로 읽는다.
        // 아래쪽 "제품별 사용량" 의 막대들은 "사용됨" 이 없어서 자연히 걸러진다.
        for (i, line) in lines.enumerated() {
            guard i >= 2, let percent = usedPercent(in: line) else { continue }
            let resetLine = lines[i - 1]
            result.append(UsageWindow(kind: kind(for: lines[i - 2]),
                                      usedPercent: percent,
                                      resetsAt: parseReset(resetLine, now: now, calendar: calendar)))
        }
        return result
    }

    static func usedPercent(in line: String) -> Double? {
        let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*%\s*(사용됨|used)$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r = Range(m.range(at: 1), in: line) else { return nil }
        return Double(line[r])
    }

    /// "오후 9:10에 재설정" · "(일요일) 오후 12:00에 재설정" · "Resets at 9:10 PM"
    ///
    /// 요일이 붙으면 다음 그 요일로 잡는다. 안 붙으면 오늘, 이미 지났으면 내일.
    public static func parseReset(_ line: String, now: Date, calendar: Calendar) -> Date? {
        guard let (hour, minute) = clock(in: line) else { return nil }

        if let weekday = weekday(in: line) {
            var comps = DateComponents()
            comps.weekday = weekday
            comps.hour = hour
            comps.minute = minute
            // 지금 이후로 처음 오는 그 요일.
            return calendar.nextDate(after: now, matching: comps,
                                     matchingPolicy: .nextTime, direction: .forward)
        }

        guard var d = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else {
            return nil
        }
        if d <= now { d = calendar.date(byAdding: .day, value: 1, to: d) ?? d }
        return d
    }

    /// 12시간제를 24시간제로. 한국어 오전/오후와 영어 AM/PM을 모두 받는다.
    static func clock(in line: String) -> (hour: Int, minute: Int)? {
        let pattern = #"(오전|오후|AM|PM)?\s*([0-9]{1,2}):([0-9]{2})\s*(AM|PM)?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let hr = Range(m.range(at: 2), in: line).map({ Int(line[$0]) }) ?? nil,
              let mr = Range(m.range(at: 3), in: line).map({ Int(line[$0]) }) ?? nil
        else { return nil }

        let prefix = Range(m.range(at: 1), in: line).map { String(line[$0]) }
        let suffix = Range(m.range(at: 4), in: line).map { String(line[$0]) }
        let marker = (prefix ?? suffix ?? "").uppercased()

        var hour = hr
        let isPM = marker == "오후" || marker == "PM"
        let isAM = marker == "오전" || marker == "AM"
        if isPM, hour < 12 { hour += 12 }
        if isAM, hour == 12 { hour = 0 }
        guard (0...23).contains(hour), (0...59).contains(minute(mr)) else { return nil }
        return (hour, mr)
    }

    private static func minute(_ m: Int) -> Int { m }

    static func weekday(in line: String) -> Int? {
        // Calendar의 weekday는 일요일이 1이다.
        let korean = ["일요일": 1, "월요일": 2, "화요일": 3, "수요일": 4,
                      "목요일": 5, "금요일": 6, "토요일": 7]
        for (name, value) in korean where line.contains(name) { return value }

        // 페이지가 "재설정: (목) 오전 2:10" 처럼 축약형을 쓰기도 한다.
        // 한 글자라 아무 데서나 찾으면 오탐이 나므로 괄호로 감싼 형태만 받는다.
        let short = ["(일)": 1, "(월)": 2, "(화)": 3, "(수)": 4,
                     "(목)": 5, "(금)": 6, "(토)": 7]
        for (name, value) in short where line.contains(name) { return value }

        let english = ["Sunday": 1, "Monday": 2, "Tuesday": 3, "Wednesday": 4,
                       "Thursday": 5, "Friday": 6, "Saturday": 7]
        for (name, value) in english where line.localizedCaseInsensitiveContains(name) { return value }
        return nil
    }
}
