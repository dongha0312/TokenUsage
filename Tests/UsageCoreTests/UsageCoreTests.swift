import XCTest
@testable import UsageCore

var seoul: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return c
}()

func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
    seoul.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

/// 표시 문자열을 검증하는 테스트의 바탕.
///
/// `L10n.isKorean` 은 기기 언어에서 초기화되는 전역 상태다. 고정하지 않으면 한국어 기기에서만
/// 통과하고 CI(영어)에서 깨진다. 실제로 그렇게 깨졌다. 게다가 한 테스트가 값을 바꾸면
/// 뒤에 도는 테스트까지 영향을 받아 실행 순서에 따라 결과가 달라진다.
class LocalizedTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        L10n.isKorean = true
    }
}

private func limit(kind: String, percent: Double, resetsAt: String?,
                   modelName: String? = nil) -> [String: Any] {
    var item: [String: Any] = ["kind": kind, "percent": percent]
    if let resetsAt { item["resets_at"] = resetsAt }
    if let modelName { item["scope"] = ["model": ["id": NSNull(), "display_name": modelName]] }
    return item
}

// MARK: - Claude 캐시 파싱

final class ClaudeLimitsTests: LocalizedTestCase {
    /// ~/.claude.json 에서 실제로 읽은 limits 배열. /usage 화면의 10% / 5% / 0% 과 같은 값.
    private let realLimits: [[String: Any]] = [
        ["kind": "session", "group": "session", "percent": 10, "severity": "normal",
         "resets_at": "2026-09-16T12:10:00.293919+00:00", "scope": NSNull(), "is_active": true],
        ["kind": "weekly_all", "group": "weekly", "percent": 5, "severity": "normal",
         "resets_at": "2026-09-20T02:59:59.293945+00:00", "scope": NSNull(), "is_active": false],
        ["kind": "weekly_scoped", "group": "weekly", "percent": 0, "severity": "normal",
         "resets_at": "2026-09-20T03:00:00+00:00",
         "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()],
         "is_active": false],
    ]

    func testParsesRealLimitsFromUsageScreen() {
        let now = date(2026, 9, 16, 17, 40)
        let w = ClaudeReader.windows(fromLimits: realLimits, now: now)
        XCTAssertEqual(w.count, 3)

        XCTAssertEqual(w[0].kind, .session(hours: 5))
        XCTAssertEqual(w[0].usedPercent ?? -1, 10, accuracy: 0.01)
        XCTAssertEqual(w[0].timeToReset(now: now), "3시간")   // 21:10 KST

        XCTAssertEqual(w[1].kind, .weeklyAllModels)
        XCTAssertEqual(w[1].usedPercent ?? -1, 5, accuracy: 0.01)

        // 모델 이름은 서버가 준 display_name을 그대로 쓴다.
        XCTAssertEqual(w[2].kind, .weeklyScoped("Fable"))
        XCTAssertEqual(w[2].usedPercent ?? -1, 0, accuracy: 0.01)
    }

    func testScopedLimitWithoutModelNameStillLabels() {
        let w = ClaudeReader.windows(
            fromLimits: [limit(kind: "weekly_scoped", percent: 3, resetsAt: nil)],
            now: date(2026, 9, 16, 17, 0))
        XCTAssertEqual(w[0].kind, .weeklyScoped("?"))
    }

    /// 새 kind가 생겨도 떨어뜨리지 않는다. 라벨만 그대로 쓴다.
    func testUnknownKindIsKeptNotDropped() {
        let w = ClaudeReader.windows(
            fromLimits: [limit(kind: "monthly_something", percent: 7, resetsAt: nil)],
            now: date(2026, 9, 16, 17, 0))
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0].kind, .other("monthly_something"))
        XCTAssertEqual(w[0].usedPercent ?? -1, 7, accuracy: 0.01)
    }

    func testUnknownScopedKindUsesModelName() {
        let w = ClaudeReader.windows(
            fromLimits: [limit(kind: "future_kind", percent: 2, resetsAt: nil, modelName: "Opus")],
            now: date(2026, 9, 16, 17, 0))
        XCTAssertEqual(w[0].kind, .weeklyScoped("Opus"))
    }

    /// 캐시는 Claude Code가 마지막으로 받아온 스냅샷이다. 리셋이 지났으면 그 창은 비워졌다.
    func testExpiredWindowIsEmptiedNotStale() {
        let now = date(2026, 9, 16, 17, 40)
        let w = ClaudeReader.windows(
            fromLimits: [limit(kind: "session", percent: 88,
                               resetsAt: "2026-09-16T05:00:00+00:00")],
            now: now)
        XCTAssertEqual(w[0].usedPercent ?? -1, 0, accuracy: 0.01)
        XCTAssertNil(w[0].resetsAt)
    }

    func testMissingPercentIsSkipped() {
        let w = ClaudeReader.windows(fromLimits: [["kind": "session"]], now: Date())
        XCTAssertTrue(w.isEmpty)
    }
}

// MARK: - Claude 날짜 파싱

final class ClaudeDateTests: XCTestCase {
    /// 서버는 소수점 6자리를 준다. ISO8601DateFormatter는 3자리를 기대하므로 따로 처리해야 한다.
    func testParsesSixDigitFractionalSeconds() {
        // 소수부까지 살아 있어야 한다. 잘라버리면 리셋 시각이 최대 1초 어긋난다.
        let d = ClaudeReader.parseDate("2026-09-16T12:10:00.293919+00:00")
        XCTAssertEqual(d?.timeIntervalSince1970 ?? 0, 1789560600.29, accuracy: 0.01)
    }

    func testParsesWithoutFraction() {
        let d = ClaudeReader.parseDate("2026-09-20T03:00:00+00:00")
        XCTAssertNotNil(d)
    }

    func testParsesZuluForm() {
        XCTAssertNotNil(ClaudeReader.parseDate("2026-09-16T12:10:00Z"))
    }

    func testRejectsGarbage() {
        XCTAssertNil(ClaudeReader.parseDate("내일쯤"))
    }
}

// MARK: - Claude 설정 파일 읽기

final class ClaudeConfigTests: LocalizedTestCase {
    private func write(_ json: Any) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    func testReadsWindowsAndFetchTime() throws {
        let fetched = date(2026, 9, 16, 17, 37)
        let url = try write([
            "cachedUsageUtilization": [
                "fetchedAtMs": fetched.timeIntervalSince1970 * 1000,
                "utilization": ["limits": [
                    ["kind": "session", "percent": 10, "resets_at": "2026-09-16T12:10:00.293919+00:00"],
                ]],
            ],
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let usage = ClaudeReader.read(configPath: url, now: date(2026, 9, 16, 17, 40))
        XCTAssertNil(usage.note)
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.updatedAt, fetched)
    }

    /// Claude Code를 한참 안 켜면 캐시가 굳는다. 임계값을 두지 않고 항상 기준 시각을 넘긴다 —
    /// UI가 "1일 전에 업데이트됨"으로 보여준다.
    func testOldCacheStillReportsItsFetchTime() throws {
        let url = try write([
            "cachedUsageUtilization": [
                "fetchedAtMs": date(2026, 9, 15, 10, 0).timeIntervalSince1970 * 1000,
                "utilization": ["limits": [
                    ["kind": "session", "percent": 10, "resets_at": "2026-09-30T00:00:00+00:00"],
                ]],
            ],
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let now = date(2026, 9, 16, 17, 40)
        let usage = ClaudeReader.read(configPath: url, now: now)
        XCTAssertNil(usage.note)
        XCTAssertEqual(updatedAgo(usage.updatedAt, now: now), "1일 전에 업데이트됨")
    }

    func testMissingFileIsReportedNotCrashed() {
        let usage = ClaudeReader.read(configPath: URL(fileURLWithPath: "/nope/missing.json"))
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertNotNil(usage.note)
    }

    func testConfigWithoutUsageCacheAsksForUsageCommand() throws {
        let url = try write(["numStartups": 3])
        defer { try? FileManager.default.removeItem(at: url) }
        let usage = ClaudeReader.read(configPath: url)
        XCTAssertTrue(usage.note?.contains("/usage") ?? false)
    }
}

// MARK: - Codex

final class CodexTests: LocalizedTestCase {
    func testMapsRealRateLimitShape() {
        let limits: [String: Any] = [
            "primary": ["used_percent": 1.0, "window_minutes": 300, "resets_at": 1789235819.0],
            "secondary": ["used_percent": 42.5, "window_minutes": 10080, "resets_at": 1789822619.0],
            "plan_type": "plus",
        ]
        let windows = CodexReader.windows(from: limits, now: Date(timeIntervalSince1970: 1789200000))
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].kind, .session(hours: 5))
        XCTAssertEqual(windows[0].usedPercent ?? -1, 1, accuracy: 0.01)
        XCTAssertEqual(windows[1].kind, .weekly)
        XCTAssertEqual(windows[1].usedPercent ?? -1, 42.5, accuracy: 0.01)
    }

    func testSkipsMissingWindow() {
        let windows = CodexReader.windows(from: ["primary": ["used_percent": 5.0, "window_minutes": 300]])
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows[0].resetsAt)
    }
}

// MARK: - Codex 스냅샷 만료

final class CodexStalenessTests: LocalizedTestCase {
    private let now = date(2026, 9, 16, 17, 0)

    func testExpiredWindowReportsEmptyNotStaleNumber() {
        let expired = now.addingTimeInterval(-2 * 3600).timeIntervalSince1970
        let windows = CodexReader.windows(
            from: ["primary": ["used_percent": 2.0, "window_minutes": 300, "resets_at": expired]],
            now: now)
        XCTAssertEqual(windows[0].usedPercent ?? -1, 0, accuracy: 0.01)
        XCTAssertNil(windows[0].resetsAt)
    }

    func testLiveWindowKeepsItsNumbers() {
        let future = now.addingTimeInterval(3 * 3600).timeIntervalSince1970
        let windows = CodexReader.windows(
            from: ["primary": ["used_percent": 45.0, "window_minutes": 10080, "resets_at": future]],
            now: now)
        XCTAssertEqual(windows[0].usedPercent ?? -1, 45, accuracy: 0.01)
        XCTAssertNotNil(windows[0].resetsAt)
    }

    func testExpiredAndLiveWindowsCoexist() {
        let windows = CodexReader.windows(from: [
            "primary": ["used_percent": 2.0, "window_minutes": 300,
                        "resets_at": now.addingTimeInterval(-3600).timeIntervalSince1970],
            "secondary": ["used_percent": 45.0, "window_minutes": 10080,
                          "resets_at": now.addingTimeInterval(3 * 86400).timeIntervalSince1970],
        ], now: now)
        XCTAssertEqual(windows[0].usedPercent ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(windows[1].usedPercent ?? -1, 45, accuracy: 0.01)
    }
}

// MARK: - Gemini 페이지 파싱

final class GeminiParseTests: LocalizedTestCase {
    private let realPage = """
    Usage limits
    PRO

    Your plan's limits determine how much you can use Gemini over time. Advanced models and features can take up more usage. Learn more

    Updated just now

    Current usage

    12% used

    Resets at 7:00 PM

    Weekly limit

    Resets Sep 22 at 2:00 PM

    34% used

    Get 5x more usage with AI Ultra
    """

    func testParsesBothWindowsFromRealPage() {
        let now = date(2026, 9, 16, 16, 0)
        let windows = GeminiParse.windows(from: realPage, now: now, calendar: seoul)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].usedPercent ?? -1, 12, accuracy: 0.01)
        XCTAssertEqual(windows[0].resetsAt, date(2026, 9, 16, 19, 0))
        XCTAssertEqual(windows[1].usedPercent ?? -1, 34, accuracy: 0.01)
        XCTAssertEqual(windows[1].resetsAt, date(2026, 9, 22, 14, 0))
    }

    func testNotLoggedInYieldsNothing() {
        XCTAssertFalse(GeminiParse.isLoaded("Sign in - Google Accounts"))
        XCTAssertTrue(GeminiParse.windows(from: "Sign in - Google Accounts").isEmpty)
    }

    func testTimeOnlyResetRollsToTomorrowWhenPassed() {
        let now = date(2026, 9, 16, 20, 0)
        XCTAssertEqual(GeminiParse.parseReset("7:00 PM", now: now, calendar: seoul),
                       date(2026, 9, 17, 19, 0))
    }

    func testDatedResetRollsToNextYearAcrossNewYear() {
        let now = date(2026, 12, 30, 10, 0)
        XCTAssertEqual(GeminiParse.parseReset("Jan 3 at 9:00 AM", now: now, calendar: seoul),
                       date(2027, 1, 3, 9, 0))
    }

    func testUnparseableResetIsNilNotCrash() {
        XCTAssertNil(GeminiParse.parseReset("in about 3 hours", now: Date(), calendar: seoul))
    }
}

// MARK: - 표시 로직

final class DisplayTests: LocalizedTestCase {
    private func usage(_ p: Provider, used: Double?) -> ProviderUsage {
        .init(provider: p,
              windows: [UsageWindow(kind: .session(hours: 5), usedPercent: used, resetsAt: nil)],
              updatedAt: Date())
    }

    /// 급한 쪽 = 가장 많이 쓴 쪽.
    func testPicksHighestUsed() {
        let picked = mostUrgent(among: [usage(.claude, used: 20), usage(.codex, used: 88),
                                        usage(.gemini, used: 45)])
        XCTAssertEqual(picked?.0.provider, .codex)
        XCTAssertEqual(picked?.1.usedPercent ?? -1, 88, accuracy: 0.01)
    }

    /// 한도를 모르는 창은 메뉴바 후보가 될 수 없다. 비율이 없으니 비교 자체가 안 된다.
    func testWindowsWithoutPercentNeverWinMenuBar() {
        let unknown = ProviderUsage(
            provider: .claude,
            windows: [UsageWindow(kind: .session(hours: 5), usedPercent: nil, resetsAt: nil)],
            updatedAt: Date())
        XCTAssertEqual(mostUrgent(among: [unknown, usage(.codex, used: 3)])?.0.provider, .codex)
    }

    func testProviderWithOnlyUnknownWindowsIsSkipped() {
        let unknown = ProviderUsage(
            provider: .claude,
            windows: [UsageWindow(kind: .session(hours: 5), usedPercent: nil, resetsAt: nil)],
            updatedAt: Date())
        XCTAssertNil(mostUrgent(among: [unknown]))
        XCTAssertEqual(menuBarText(for: [unknown]), "—")
    }

    func testMenuBarShowsRemainingNotUsed() {
        let now = date(2026, 9, 16, 17, 0)
        let u = ProviderUsage(
            provider: .claude,
            windows: [UsageWindow(kind: .session(hours: 5), usedPercent: 11,
                                  resetsAt: now.addingTimeInterval(3 * 3600 + 600))],
            updatedAt: now)
        XCTAssertEqual(menuBarText(for: [u], now: now), "89% 남음 · 3시간")
    }

    /// 패널의 사용 비율과 합이 100이어야 한다. 33.5를 따로 반올림하면 34 + 67 = 101이 된다.
    func testRemainingAddsUpWithPanel() {
        let u = ProviderUsage(
            provider: .claude,
            windows: [UsageWindow(kind: .session(hours: 5), usedPercent: 33.5, resetsAt: nil)],
            updatedAt: Date())
        XCTAssertEqual(menuBarText(for: [u]), "66% 남음")
    }

    func testAllUnavailableGivesDash() {
        XCTAssertEqual(menuBarText(for: [.unavailable(.gemini, "x"), .unavailable(.codex, "y")]), "—")
    }

    /// 목업의 오른쪽 문구: "11% · 3시간 후 초기화"
    func testSummaryLine() {
        let now = date(2026, 9, 16, 17, 0)
        let w = UsageWindow(kind: .session(hours: 5), usedPercent: 11,
                            resetsAt: now.addingTimeInterval(3 * 3600 + 600))
        XCTAssertEqual(w.summary(now: now), "11% · 3시간 후 초기화")
    }

    func testSummaryWithoutResetOmitsTail() {
        let w = UsageWindow(kind: .session(hours: 5), usedPercent: 0, resetsAt: nil)
        XCTAssertEqual(w.summary(), "0%")
    }

    func testUpdatedAgoWording() {
        let now = date(2026, 9, 16, 17, 0)
        XCTAssertEqual(updatedAgo(now.addingTimeInterval(-30), now: now), "방금 업데이트됨")
        XCTAssertEqual(updatedAgo(now.addingTimeInterval(-14 * 60), now: now), "14분 전에 업데이트됨")
        XCTAssertEqual(updatedAgo(now.addingTimeInterval(-3 * 3600), now: now), "3시간 전에 업데이트됨")
        XCTAssertEqual(updatedAgo(now.addingTimeInterval(-2 * 86400), now: now), "2일 전에 업데이트됨")
        XCTAssertNil(updatedAgo(nil, now: now))
    }

    func testPlanNames() {
        XCTAssertEqual(ClaudeReader.planName("claude_max"), "MAX")
        XCTAssertEqual(ClaudeReader.planName("claude_pro"), "PRO")
        XCTAssertNil(ClaudeReader.planName(nil))
        XCTAssertEqual(CodexReader.planName("plus"), "PLUS")
        XCTAssertNil(CodexReader.planName(nil))
        XCTAssertEqual(GeminiParse.plan(from: "Usage limits\nPRO\n\nYour plan's limits"), "PRO")
        XCTAssertNil(GeminiParse.plan(from: "Sign in"))
    }
}

// MARK: - 남은 시간 표기

final class TimeToResetTests: LocalizedTestCase {
    private let now = date(2026, 9, 16, 17, 0)

    private func window(_ seconds: TimeInterval) -> UsageWindow {
        UsageWindow(kind: .session(hours: 5), usedPercent: 0, resetsAt: now.addingTimeInterval(seconds))
    }

    /// 주간 창을 "76:53"으로 찍으면 읽히지 않는다. 눈금 하나만 쓴다.
    func testWeeklyWindowUsesDays() {
        XCTAssertEqual(window(76 * 3600 + 53 * 60).timeToReset(now: now), "3일")
    }

    func testHoursRoundDown() {
        XCTAssertEqual(window(3 * 3600 + 26 * 60).timeToReset(now: now), "3시간")
    }

    func testUnderAnHourUsesMinutes() {
        XCTAssertEqual(window(47 * 60).timeToReset(now: now), "47분")
    }

    /// 몇 초 남았어도 "0분"이라고 하지 않는다.
    func testAlmostExpiredStillShowsAMinute() {
        XCTAssertEqual(window(20).timeToReset(now: now), "1분")
    }

    func testPastResetIsNil() {
        XCTAssertNil(window(-60).timeToReset(now: now))
    }
}

// MARK: - claude.ai 사용량 페이지 파싱

final class ClaudeWebParseTests: LocalizedTestCase {
    /// claude.ai/settings/usage 에서 실제로 캡처한 텍스트.
    /// 아래쪽 "제품별 사용량" 의 100% / 0% 막대가 한도로 오해되지 않아야 한다.
    private let realPage = """
    사용량

    사용량
    Max (5x)

    새로운 한 주입니다. 주간 한도의 5%를 사용했습니다.

    알림: 주간 한도를 50% 상향했던 프로모션이 종료되었습니다. 자세히 알아보기
    현재 세션
    오후 9:10에 재설정
    14% 사용됨
    이번 주
    (일요일) 오후 12:00에 재설정
    5% 사용됨
    이번 주 Fable
    별도 주간 한도 대상: Fable · (일요일) 오후 12:00에 재설정
    0% 사용됨
    사용 크레딧
    모든 작업에 사용할 수 있습니다.
    US$42.13
    이번 주 제품별 사용량
    Claude Code
    100%
    채팅
    0%
    마지막 업데이트: 1분 전
    """

    func testParsesThreeWindowsFromRealPage() {
        let now = date(2026, 9, 16, 17, 40)   // 수요일
        let w = ClaudeWebParse.windows(from: realPage, now: now, calendar: seoul)
        XCTAssertEqual(w.count, 3, "제품별 사용량 막대가 섞여 들어왔을 수 있다")

        XCTAssertEqual(w[0].kind, .session(hours: 5))
        XCTAssertEqual(w[0].usedPercent ?? -1, 14, accuracy: 0.01)
        XCTAssertEqual(w[0].resetsAt, date(2026, 9, 16, 21, 10))

        XCTAssertEqual(w[1].kind, .weeklyAllModels)
        XCTAssertEqual(w[1].usedPercent ?? -1, 5, accuracy: 0.01)
        XCTAssertEqual(w[1].resetsAt, date(2026, 9, 20, 12, 0))   // 다음 일요일

        XCTAssertEqual(w[2].kind, .weeklyScoped("Fable"))
        XCTAssertEqual(w[2].usedPercent ?? -1, 0, accuracy: 0.01)
    }

    /// 웹이 로컬 캐시보다 신선하다는 게 이 경로의 존재 이유다.
    func testWebValueDiffersFromStaleCache() {
        let w = ClaudeWebParse.windows(from: realPage, now: date(2026, 9, 16, 17, 40),
                                       calendar: seoul)
        XCTAssertEqual(w[0].usedPercent ?? -1, 14, accuracy: 0.01)   // 같은 시각 캐시는 10이었다
    }

    func testPlanSkipsRepeatedTitle() {
        XCTAssertEqual(ClaudeWebParse.plan(from: realPage), "Max (5x)")
    }

    func testNotLoggedInYieldsNothing() {
        XCTAssertFalse(ClaudeWebParse.isLoaded("로그인하세요"))
        XCTAssertTrue(ClaudeWebParse.windows(from: "로그인하세요").isEmpty)
    }

    func testAfternoonClockConvertsTo24Hour() {
        let now = date(2026, 9, 16, 10, 0)
        XCTAssertEqual(ClaudeWebParse.parseReset("오후 9:10에 재설정", now: now, calendar: seoul),
                       date(2026, 9, 16, 21, 10))
    }

    func testNoonIsTwelvePM() {
        let now = date(2026, 9, 16, 10, 0)
        XCTAssertEqual(ClaudeWebParse.parseReset("오후 12:00에 재설정", now: now, calendar: seoul),
                       date(2026, 9, 16, 12, 0))
    }

    func testMidnightIsTwelveAM() {
        let now = date(2026, 9, 16, 22, 0)
        XCTAssertEqual(ClaudeWebParse.parseReset("오전 12:00에 재설정", now: now, calendar: seoul),
                       date(2026, 9, 17, 0, 0))
    }

    func testPassedTimeRollsToTomorrow() {
        let now = date(2026, 9, 16, 22, 0)
        XCTAssertEqual(ClaudeWebParse.parseReset("오후 9:10에 재설정", now: now, calendar: seoul),
                       date(2026, 9, 17, 21, 10))
    }

    /// 요일이 붙으면 다음 그 요일로 잡아야 한다. 오늘/내일로 계산하면 안 된다.
    func testWeekdayGoesToNextOccurrence() {
        let now = date(2026, 9, 16, 17, 40)   // 수요일
        XCTAssertEqual(ClaudeWebParse.parseReset("(일요일) 오후 12:00에 재설정",
                                                 now: now, calendar: seoul),
                       date(2026, 9, 20, 12, 0))
    }

    func testEnglishPageAlsoParses() {
        let english = """
        Usage
        Max (5x)
        Current session
        Resets at 9:10 PM
        14% used
        Current week
        Resets Sunday at 12:00 PM
        5% used
        """
        let now = date(2026, 9, 16, 17, 40)
        let w = ClaudeWebParse.windows(from: english, now: now, calendar: seoul)
        XCTAssertEqual(w.count, 2)
        XCTAssertEqual(w[0].kind, .session(hours: 5))
        XCTAssertEqual(w[0].usedPercent ?? -1, 14, accuracy: 0.01)
        XCTAssertEqual(w[1].resetsAt, date(2026, 9, 20, 12, 0))
    }
}

// MARK: - chatgpt.com Codex 사용량 페이지 파싱

final class CodexWebParseTests: LocalizedTestCase {
    /// chatgpt.com/codex/cloud/settings/analytics#usage 에서 실제로 캡처한 텍스트.
    /// 퍼센트와 "남음"이 다른 줄에 있고, 아래쪽 차트에도 0%/100% 축 눈금이 있다.
    private let realPage = """
    코딩
    앱
    Docs
    PLUS
    GitHub 계정이 연결되어 있지 않습니다.
    설정
    Codex 및 Work 분석
    잔액

    Codex와 Work는 동일한 사용 한도를 공유합니다.

    5시간 사용 한도

    100%
    남음

    주간 사용 한도

    55%
    남음
    2026. 9. 19. 오후 9:57 초기화

    남은 크레딧

    0
    사용량 세부 정보
    개인 사용량
    8월 18일
    9월 16일
    0%
    100%
    Desktop App
    CLI
    웹
    """

    func testParsesTwoLimitsFromRealPage() {
        let now = date(2026, 9, 16, 19, 0)
        let w = CodexWebParse.windows(from: realPage, now: now, calendar: seoul)
        XCTAssertEqual(w.count, 2, "아래쪽 차트의 0%/100% 축 눈금이 섞여 들어왔을 수 있다")
        XCTAssertEqual(w[0].kind, .session(hours: 5))
        XCTAssertEqual(w[1].kind, .weekly, "Codex에는 모델별 주간 한도가 없다")
    }

    /// 페이지는 "남은 비율"로 보여준다. 앱 전체는 사용률 기준이라 뒤집어야 한다.
    func testConvertsRemainingToUsed() {
        let w = CodexWebParse.windows(from: realPage, now: date(2026, 9, 16, 19, 0),
                                      calendar: seoul)
        XCTAssertEqual(w[0].usedPercent ?? -1, 0, accuracy: 0.01)    // 100% 남음
        XCTAssertEqual(w[1].usedPercent ?? -1, 45, accuracy: 0.01)   // 55% 남음
    }

    /// 로컬 세션 로그 판독과 같은 값이 나와야 한다. 두 경로가 어긋나면 하나가 틀린 것이다.
    func testMatchesLocalLogReading() {
        let web = CodexWebParse.windows(from: realPage, now: date(2026, 9, 16, 19, 0),
                                        calendar: seoul)
        let local = CodexReader.windows(from: [
            "primary": ["used_percent": 0.0, "window_minutes": 300,
                        "resets_at": date(2026, 9, 16, 23, 0).timeIntervalSince1970],
            "secondary": ["used_percent": 45.0, "window_minutes": 10080,
                          "resets_at": date(2026, 9, 19, 21, 57).timeIntervalSince1970],
        ], now: date(2026, 9, 16, 19, 0))
        XCTAssertEqual(web[1].usedPercent ?? -1, local[1].usedPercent ?? -2, accuracy: 0.01)
        XCTAssertEqual(web[1].resetsAt, local[1].resetsAt)
    }

    func testParsesKoreanResetTimestamp() {
        let d = CodexWebParse.parseReset("2026. 9. 19. 오후 9:57 초기화",
                                         now: date(2026, 9, 16, 19, 0), calendar: seoul)
        XCTAssertEqual(d, date(2026, 9, 19, 21, 57))
    }

    func testResetLineWithoutKeywordIsIgnored() {
        // "주간 사용 한도" 같은 다음 라벨이 리셋으로 오해되면 안 된다.
        XCTAssertNil(CodexWebParse.parseReset("주간 사용 한도",
                                              now: Date(), calendar: seoul))
    }

    func testFiveHourWindowHasNoResetWhenPageOmitsIt() {
        let w = CodexWebParse.windows(from: realPage, now: date(2026, 9, 16, 19, 0),
                                      calendar: seoul)
        XCTAssertNil(w[0].resetsAt)
        XCTAssertEqual(w[1].resetsAt, date(2026, 9, 19, 21, 57))
    }

    func testPlanBadge() {
        XCTAssertEqual(CodexWebParse.plan(from: realPage), "PLUS")
        XCTAssertNil(CodexWebParse.plan(from: "로그인하세요"))
    }

    func testNotLoggedInYieldsNothing() {
        XCTAssertFalse(CodexWebParse.isLoaded("Log in to ChatGPT"))
        XCTAssertTrue(CodexWebParse.windows(from: "Log in to ChatGPT").isEmpty)
    }
}

// MARK: - 다국어 · 라벨

final class LocalizationTests: LocalizedTestCase {
    /// 파서는 문구가 아니라 의미를 넘긴다. 표시 언어는 시스템을 따른다.
    func testSameKindRendersInBothLanguages() {
        L10n.isKorean = true
        XCTAssertEqual(L10n.label(for: .session(hours: 5)), "5시간 한도")
        XCTAssertEqual(L10n.label(for: .weekly), "주간 한도")
        XCTAssertEqual(L10n.label(for: .weeklyAllModels), "주간 · 모든 모델")
        XCTAssertEqual(L10n.label(for: .weeklyScoped("Fable")), "주간 · Fable")

        L10n.isKorean = false
        XCTAssertEqual(L10n.label(for: .session(hours: 5)), "5-hour limit")
        XCTAssertEqual(L10n.label(for: .weekly), "Weekly limit")
        XCTAssertEqual(L10n.label(for: .weeklyAllModels), "Weekly · all models")
        XCTAssertEqual(L10n.label(for: .weeklyScoped("Fable")), "Weekly · Fable")
    }

    /// 모르는 종류는 벤더 문구를 그대로 통과시킨다. 번역한답시고 버리면 안 된다.
    func testUnknownKindPassesThrough() {
        L10n.isKorean = false
        XCTAssertEqual(L10n.label(for: .other("monthly_quota")), "monthly_quota")
    }

    func testSummaryFollowsLanguage() {
        let now = date(2026, 9, 16, 17, 0)
        let w = UsageWindow(kind: .session(hours: 5), usedPercent: 11,
                            resetsAt: now.addingTimeInterval(3 * 3600 + 600))
        L10n.isKorean = true
        XCTAssertEqual(w.summary(now: now), "11% · 3시간 후 초기화")
        L10n.isKorean = false
        XCTAssertEqual(w.summary(now: now), "11% · resets in 3h")
    }

    func testUpdatedAgoFollowsLanguage() {
        let now = date(2026, 9, 16, 17, 0)
        L10n.isKorean = true
        XCTAssertEqual(updatedAgo(now.addingTimeInterval(-14 * 60), now: now), "14분 전에 업데이트됨")
        L10n.isKorean = false
        XCTAssertEqual(updatedAgo(now.addingTimeInterval(-14 * 60), now: now), "updated 14m ago")
    }

    func testKindIdIsStableForDeduplication() {
        XCTAssertEqual(WindowKind.weeklyScoped("Fable").id, "weekly:Fable")
        XCTAssertNotEqual(WindowKind.weekly.id, WindowKind.weeklyScoped("Fable").id)
    }
}

// MARK: - 경고 단계

final class SeverityTests: XCTestCase {
    private func window(_ used: Double) -> UsageWindow {
        UsageWindow(kind: .session(hours: 5), usedPercent: used, resetsAt: nil)
    }

    func testThresholds() {
        XCTAssertEqual(window(0).severity, .normal)
        XCTAssertEqual(window(79.9).severity, .normal)
        XCTAssertEqual(window(80).severity, .warning)
        XCTAssertEqual(window(94.9).severity, .warning)
        XCTAssertEqual(window(95).severity, .critical)
        XCTAssertEqual(window(100).severity, .critical)
    }

    /// 한도를 모르는 창은 경고하지 않는다. 비율이 없으니 판단 근거가 없다.
    func testUnknownPercentIsNormal() {
        XCTAssertEqual(UsageWindow(kind: .weekly, usedPercent: nil, resetsAt: nil).severity, .normal)
    }
}

// MARK: - claude.ai 축약 요일

final class ClaudeWeekdayTests: LocalizedTestCase {
    /// 페이지가 "재설정: (목) 오전 2:10" 처럼 축약형을 쓴다.
    /// 전체 이름만 찾으면 "오늘/내일"로 잘못 계산해 며칠씩 어긋난다.
    func testAbbreviatedWeekday() {
        let now = date(2026, 9, 16, 22, 54)   // 수요일 밤
        XCTAssertEqual(ClaudeWebParse.parseReset("재설정: (목) 오전 2:10", now: now, calendar: seoul),
                       date(2026, 9, 17, 2, 10))
    }

    /// 축약형이 먼 요일을 가리키면 오늘/내일 계산과 결과가 달라진다. 여기서 차이가 드러난다.
    func testAbbreviatedWeekdayFarAway() {
        let now = date(2026, 9, 16, 10, 0)    // 수요일
        XCTAssertEqual(ClaudeWebParse.parseReset("재설정: (토) 오후 3:00", now: now, calendar: seoul),
                       date(2026, 9, 19, 15, 0))
    }

    func testFullWeekdayStillWorks() {
        let now = date(2026, 9, 16, 17, 40)
        XCTAssertEqual(ClaudeWebParse.parseReset("재설정: (일요일) 오후 12:00",
                                                 now: now, calendar: seoul),
                       date(2026, 9, 20, 12, 0))
    }

    /// 괄호 없는 한 글자는 무시해야 한다. 아무 문장에나 "토"가 들어갈 수 있다.
    func testBareSingleCharIsNotAWeekday() {
        let now = date(2026, 9, 16, 10, 0)
        // "토큰" 의 "토" 를 토요일로 읽으면 안 된다.
        XCTAssertEqual(ClaudeWebParse.parseReset("토큰 재설정: 오후 3:00", now: now, calendar: seoul),
                       date(2026, 9, 16, 15, 0))
    }

    /// 실제로 관찰된 새 문구 형식 전체.
    func testCurrentPageFormat() {
        let page = """
        사용량
        Max (5x)
        현재 세션
        재설정: (목) 오전 2:10
        4% 사용됨
        이번 주
        재설정: (일요일) 오후 12:00
        7% 사용됨
        이번 주 Fable
        별도 주간 한도 대상: Fable · 재설정: (일요일) 오후 12:00
        1% 사용됨
        """
        let now = date(2026, 9, 16, 22, 54)
        let w = ClaudeWebParse.windows(from: page, now: now, calendar: seoul)
        XCTAssertEqual(w.count, 3)
        XCTAssertEqual(w[0].kind, .session(hours: 5))
        XCTAssertEqual(w[0].usedPercent ?? -1, 4, accuracy: 0.01)
        XCTAssertEqual(w[0].resetsAt, date(2026, 9, 17, 2, 10))
        XCTAssertEqual(w[1].usedPercent ?? -1, 7, accuracy: 0.01)
        XCTAssertEqual(w[2].kind, .weeklyScoped("Fable"))
        XCTAssertEqual(w[2].usedPercent ?? -1, 1, accuracy: 0.01)
    }
}

// MARK: - 리셋 시각 보완

final class FillMissingResetsTests: XCTestCase {
    private let now = date(2026, 9, 16, 19, 0)

    private func window(_ kind: WindowKind, used: Double, reset: Date?) -> UsageWindow {
        UsageWindow(kind: kind, usedPercent: used, resetsAt: reset)
    }

    /// 웹이 날짜 문구를 못 읽어도 퍼센트는 살아 있다. 시각만 로컬에서 빌려온다.
    func testFillsMissingResetFromLocal() {
        let web = [window(.weekly, used: 45, reset: nil)]
        let local = [window(.weekly, used: 45, reset: date(2026, 9, 19, 21, 57))]
        let merged = fillingMissingResets(web, from: local)
        XCTAssertEqual(merged[0].resetsAt, date(2026, 9, 19, 21, 57))
        XCTAssertEqual(merged[0].usedPercent ?? -1, 45, accuracy: 0.01)
    }

    /// 웹이 시각을 줬으면 그게 최신이다. 로컬로 덮어쓰면 안 된다.
    func testKeepsWebResetWhenPresent() {
        let web = [window(.session(hours: 5), used: 4, reset: date(2026, 9, 17, 2, 10))]
        let local = [window(.session(hours: 5), used: 99, reset: date(2026, 9, 16, 1, 0))]
        XCTAssertEqual(fillingMissingResets(web, from: local)[0].resetsAt,
                       date(2026, 9, 17, 2, 10))
    }

    /// 종류가 다르면 엉뚱한 시각을 가져오면 안 된다.
    func testDoesNotMatchAcrossKinds() {
        let web = [window(.session(hours: 5), used: 4, reset: nil)]
        let local = [window(.weekly, used: 45, reset: date(2026, 9, 19, 21, 57))]
        XCTAssertNil(fillingMissingResets(web, from: local)[0].resetsAt)
    }

    func testModelScopedMatchesByModelName() {
        let web = [window(.weeklyScoped("Fable"), used: 1, reset: nil)]
        let local = [window(.weeklyScoped("Opus"), used: 3, reset: date(2026, 9, 20, 12, 0)),
                     window(.weeklyScoped("Fable"), used: 1, reset: date(2026, 9, 21, 12, 0))]
        XCTAssertEqual(fillingMissingResets(web, from: local)[0].resetsAt,
                       date(2026, 9, 21, 12, 0))
    }

    func testEmptyLocalIsHarmless() {
        let web = [window(.weekly, used: 45, reset: nil)]
        XCTAssertNil(fillingMissingResets(web, from: [])[0].resetsAt)
    }
}

// MARK: - 창 길이를 지어내지 않는다

final class SessionLengthTests: LocalizedTestCase {
    /// Gemini는 현재 창의 길이를 공개하지 않는다.
    /// 여기에 5를 넣으면 "5시간 한도"라고 거짓말하게 된다.
    func testGeminiSessionHasNoStatedLength() {
        let page = """
        Usage limits
        PRO
        Current usage
        0% used
        Resets at 7:00 PM
        Weekly limit
        Resets Sep 22 at 2:00 PM
        0% used
        """
        let w = GeminiParse.windows(from: page, now: date(2026, 9, 16, 16, 0), calendar: seoul)
        XCTAssertEqual(w[0].kind, .session(hours: nil))
        XCTAssertEqual(w[1].kind, .weekly)

        L10n.isKorean = true
        XCTAssertEqual(w[0].label, "현재 한도")
        L10n.isKorean = false
        XCTAssertEqual(w[0].label, "Current limit")
    }

    /// Codex는 window_minutes 로 길이를 알려준다. 300분이 아니어도 그 값을 써야 한다.
    func testCodexUsesReportedWindowLength() {
        XCTAssertEqual(CodexReader.kind(forMinutes: 300), .session(hours: 5))
        XCTAssertEqual(CodexReader.kind(forMinutes: 180), .session(hours: 3))
        XCTAssertEqual(CodexReader.kind(forMinutes: 10080), .weekly)
    }

    /// 길이가 다르면 다른 창이다. 같은 키로 묶이면 안 된다.
    func testDifferentLengthsAreDistinctKinds() {
        XCTAssertNotEqual(WindowKind.session(hours: 5).id, WindowKind.session(hours: 3).id)
        XCTAssertNotEqual(WindowKind.session(hours: nil).id, WindowKind.session(hours: 5).id)
    }
}

// MARK: - 메뉴바 기준 선택

final class MenuBarSelectionTests: LocalizedTestCase {
    private func usage(_ p: Provider, session: Double?, weekly: Double?) -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let session { windows.append(UsageWindow(kind: .session(hours: 5), usedPercent: session, resetsAt: nil)) }
        if let weekly { windows.append(UsageWindow(kind: .weekly, usedPercent: weekly, resetsAt: nil)) }
        return ProviderUsage(provider: p, windows: windows, updatedAt: Date())
    }

    /// 실제로 겪은 상황: Codex 주간 45% 가 Codex 세션 2% 를 가려서,
    /// 정작 여유가 많은 서비스가 제일 급한 것처럼 메뉴바에 올라갔다.
    func testWeeklyDoesNotMaskSession() {
        let picked = mostUrgent(among: [
            usage(.claude, session: 23, weekly: 9),
            usage(.codex, session: 2, weekly: 45),
            usage(.gemini, session: 0, weekly: 0),
        ])
        XCTAssertEqual(picked?.0.provider, .claude, "세션이 가장 높은 쪽이 올라와야 한다")
        XCTAssertEqual(picked?.1.usedPercent ?? -1, 23, accuracy: 0.01)
    }

    /// 주간이 진짜 위험해지면 숨기면 안 된다.
    func testDangerousWeeklyStillSurfaces() {
        let picked = mostUrgent(among: [
            usage(.claude, session: 23, weekly: 9),
            usage(.codex, session: 2, weekly: 92),
        ])
        XCTAssertEqual(picked?.0.provider, .codex)
        XCTAssertEqual(picked?.1.kind, .weekly)
    }

    /// 경고 문턱(80%) 아래의 주간은 여전히 조용하다.
    func testWeeklyJustBelowThresholdStaysQuiet() {
        let picked = mostUrgent(among: [
            usage(.claude, session: 10, weekly: 79),
        ])
        XCTAssertEqual(picked?.1.kind, .session(hours: 5))
    }

    /// 세션 창이 없는 제공자만 있으면 그거라도 보여준다.
    func testFallsBackWhenNoSessionWindows() {
        let picked = mostUrgent(among: [usage(.gemini, session: nil, weekly: 30)])
        XCTAssertEqual(picked?.1.kind, .weekly)
    }

    func testNothingUsableGivesNil() {
        XCTAssertNil(mostUrgent(among: [.unavailable(.claude, "x")]))
    }
}

// MARK: - 메뉴바 표시 방식 · 갱신 주기

final class MenuBarStyleTests: LocalizedTestCase {
    private func usage(_ p: Provider, session: Double?, weekly: Double?) -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let session { windows.append(UsageWindow(kind: .session(hours: 5), usedPercent: session, resetsAt: nil)) }
        if let weekly { windows.append(UsageWindow(kind: .weekly, usedPercent: weekly, resetsAt: nil)) }
        return ProviderUsage(provider: p, windows: windows, updatedAt: Date())
    }

    func testAllModeListsEveryProviderInOrder() {
        let entries = menuBarEntries(for: [
            usage(.claude, session: 23, weekly: 9),
            usage(.codex, session: 2, weekly: 45),
            usage(.gemini, session: 0, weekly: 0),
        ])
        XCTAssertEqual(entries.map(\.provider), [.claude, .codex, .gemini])
        XCTAssertEqual(entries.map(\.text), ["77%", "98%", "100%"])
    }

    /// 제공자 안에서도 세션을 우선한다. 전체 규칙과 어긋나면 숫자가 서로 안 맞아 보인다.
    func testAllModePrefersSessionWithinProvider() {
        let entries = menuBarEntries(for: [usage(.codex, session: 2, weekly: 45)])
        XCTAssertEqual(entries.first?.text, "98%", "주간 45% 가 아니라 세션 2% 여야 한다")
    }

    /// 세션 창이 없는 제공자는 가진 것 중 최대를 쓴다.
    func testAllModeFallsBackWhenNoSession() {
        XCTAssertEqual(menuBarEntries(for: [usage(.gemini, session: nil, weekly: 30)]).first?.text, "70%")
    }

    /// 수치가 없는 제공자는 아예 빠진다. "—" 같은 자리만 차지하는 항목을 만들지 않는다.
    func testAllModeSkipsProvidersWithoutNumbers() {
        let entries = menuBarEntries(for: [
            .unavailable(.gemini, "로그인 필요"),
            usage(.claude, session: 5, weekly: nil),
        ])
        XCTAssertEqual(entries.map(\.provider), [.claude])
    }

    /// 틀리면 최신 버전 사용자에게 업데이트가 뜨거나, 진짜 업데이트를 놓친다.
    func testVersionComparison() {
        XCTAssertTrue(isNewerVersion("v1.1.0", than: "1.0"))
        XCTAssertTrue(isNewerVersion("v1.10.0", than: "1.9.0"), "문자열 비교면 틀린다")
        XCTAssertTrue(isNewerVersion("v2.0", than: "1.99.99"))
        XCTAssertFalse(isNewerVersion("v1.1.0", than: "1.1"), "자리 수만 다른 같은 버전")
        XCTAssertFalse(isNewerVersion("v1.0.0", than: "1.1.0"))
        XCTAssertFalse(isNewerVersion("v1.1.0", than: "1.1.0"))
    }

    func testRefreshIntervalRoundTripsThroughRawValue() {
        for interval in RefreshInterval.allCases {
            XCTAssertEqual(RefreshInterval(rawValue: interval.rawValue), interval)
        }
        // 저장된 값이 깨졌거나 비어 있으면 기본값으로 떨어져야 한다.
        XCTAssertNil(RefreshInterval(rawValue: 0))
        XCTAssertNil(RefreshInterval(rawValue: 7))
    }

    func testMenuBarStyleRoundTrips() {
        for style in MenuBarStyle.allCases {
            XCTAssertEqual(MenuBarStyle(rawValue: style.rawValue), style)
        }
        XCTAssertNil(MenuBarStyle(rawValue: "nope"))
    }
}
