// Core.cs 검증. Tests/UsageCoreTests 의 케이스를 그대로 옮겼다 (페이지 텍스트도 실제 캡처본 그대로).
// 어느 OS에서나 돈다:  dotnet run --project windows/check
using System.Text.Json.Nodes;
using TokenUsage;
using static TokenUsage.Usage;

var seoul = TimeZoneInfo.FindSystemTimeZoneById("Asia/Seoul");
DateTimeOffset D(int y, int mo, int d, int h, int mi = 0) => At(seoul, new DateTime(y, mo, d), h, mi);
int failures = 0, checks = 0;
void Eq<T>(T actual, T expected, string what)
{
    checks++;
    if (EqualityComparer<T>.Default.Equals(actual, expected)) return;
    failures++;
    Console.WriteLine($"FAIL {what}: expected <{expected}> got <{actual}>");
}
UsageWindow W(WindowKind k, double? used, DateTimeOffset? reset = null) => new(k, used, reset);
ProviderUsage U(Provider p, double? session, double? weekly)
{
    var ws = new List<UsageWindow>();
    if (session != null) ws.Add(W(new WindowKind.Session(5), session));
    if (weekly != null) ws.Add(W(new WindowKind.Weekly(), weekly));
    return new(p, ws, DateTimeOffset.Now);
}
L10n.IsKorean = true;

// --- Claude 캐시 (~/.claude.json limits)
{
    var limits = JsonNode.Parse("""
    [{"kind":"session","percent":10,"resets_at":"2026-09-16T12:10:00.293919+00:00","scope":null},
     {"kind":"weekly_all","percent":5,"resets_at":"2026-09-20T02:59:59.293945+00:00","scope":null},
     {"kind":"weekly_scoped","percent":0,"resets_at":"2026-09-20T03:00:00+00:00",
      "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}},
     {"kind":"monthly_something","percent":7},
     {"kind":"weekly_scoped","percent":3},
     {"kind":"session"}]
    """)!.AsArray();
    var now = D(2026, 9, 16, 17, 40);
    var w = ClaudeReader.Windows(limits, now);
    Eq(w.Count, 5, "claude limits count (percent 없는 항목은 건너뜀)");
    Eq(w[0].Kind, new WindowKind.Session(5), "claude session kind");
    Eq(w[0].UsedPercent, 10.0, "claude session %");
    Eq(w[0].TimeToReset(now), "3시간", "claude session reset");
    Eq(w[1].Kind, new WindowKind.WeeklyAllModels(), "claude weekly_all");
    Eq(w[2].Kind, new WindowKind.WeeklyScoped("Fable"), "claude scoped model");
    Eq(w[3].Kind, new WindowKind.Other("monthly_something"), "unknown kind kept");
    Eq(w[4].Kind, new WindowKind.WeeklyScoped("?"), "scoped without name");

    var expired = ClaudeReader.Windows(JsonNode.Parse("""[{"kind":"session","percent":80,"resets_at":"2026-09-16T00:00:00Z"}]""")!.AsArray(), now);
    Eq(expired[0].UsedPercent, 0.0, "expired window emptied");
    Eq(expired[0].ResetsAt, null, "expired window has no reset");

    Eq(ClaudeReader.ParseDate("2026-09-16T12:10:00.293919+00:00")?.ToUnixTimeMilliseconds(), 1789560600293L, "6-digit fraction");
    Eq(ClaudeReader.ParseDate("2026-09-20T03:00:00+00:00") != null, true, "no fraction");
    Eq(ClaudeReader.ParseDate("2026-09-16T12:10:00Z") != null, true, "zulu");
    Eq(ClaudeReader.ParseDate("내일쯤"), null, "garbage date");
    Eq(ClaudeReader.ParseDate("9/16/2026"), null, "non-ISO date");

    var tmp = Path.GetTempFileName();
    File.WriteAllText(tmp, """
    {"oauthAccount":{"organizationType":"claude_max"},
     "cachedUsageUtilization":{"fetchedAtMs":1789550000000,"utilization":{"limits":[{"kind":"session","percent":12,"resets_at":"2099-01-01T00:00:00Z"}]}}}
    """);
    var read = ClaudeReader.Read(now, tmp);
    Eq(read.Plan, "MAX", "claude plan name");
    Eq(read.Windows.Count, 1, "claude file windows");
    Eq(read.UpdatedAt?.ToUnixTimeMilliseconds(), 1789550000000L, "claude fetchedAt");
    File.WriteAllText(tmp, """{"oauthAccount":{}}""");
    Eq(ClaudeReader.Read(now, tmp).Note, L10n.NoUsageCache, "config without cache");
    File.Delete(tmp);
    Eq(ClaudeReader.Read(now, tmp).Note, L10n.ConfigUnreadable, "missing config");
}

// --- Codex 세션 로그
{
    var now = D(2026, 9, 16, 19, 0);
    var limits = JsonNode.Parse($$"""
    {"primary":{"used_percent":0.0,"window_minutes":300,"resets_at":{{D(2026, 9, 16, 23, 0).ToUnixTimeSeconds()}}},
     "secondary":{"used_percent":45.0,"window_minutes":10080,"resets_at":{{D(2026, 9, 19, 21, 57).ToUnixTimeSeconds()}}},
     "plan_type":"plus"}
    """)!;
    var w = CodexReader.Windows(limits, now);
    Eq(w.Count, 2, "codex windows");
    Eq(w[1].UsedPercent, 45.0, "codex weekly used");
    Eq(CodexReader.Kind(300), new WindowKind.Session(5), "codex 300m");
    Eq(CodexReader.Kind(180), new WindowKind.Session(3), "codex 180m");
    Eq(CodexReader.Kind(10080), new WindowKind.Weekly(), "codex 10080m");

    var expired = CodexReader.Windows(JsonNode.Parse("""{"primary":{"used_percent":70,"window_minutes":300,"resets_at":1}}""")!, now);
    Eq(expired[0].UsedPercent, 0.0, "codex expired emptied");

    var dir = Path.Combine(Path.GetTempPath(), "tu-check-" + Guid.NewGuid());
    Directory.CreateDirectory(Path.Combine(dir, "2026", "09"));
    File.WriteAllText(Path.Combine(dir, "2026", "09", "s.jsonl"),
        "{\"type\":\"other\"}\n" +
        "{\"timestamp\":\"2026-09-16T10:00:00Z\",\"payload\":{\"rate_limits\":" + limits.ToJsonString() + "}}\n" +
        "{\"type\":\"tail\"}\n");
    var read = CodexReader.Read(now, dir);
    Eq(read.Plan, "PLUS", "codex plan");
    Eq(read.Windows.Count, 2, "codex file windows");
    Eq(read.UpdatedAt, ClaudeReader.ParseDate("2026-09-16T10:00:00Z"), "codex recordedAt");
    Directory.Delete(dir, true);
    Eq(CodexReader.Read(now, dir).Note, L10n.NoSessionLogs, "codex no dir");
}

// --- Gemini 페이지
{
    var page = """
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
    """;
    var w = GeminiParse.Windows(page, D(2026, 9, 16, 16, 0), seoul);
    Eq(w.Count, 2, "gemini windows");
    Eq(w[0].UsedPercent, 12.0, "gemini current %");
    Eq(w[0].ResetsAt, D(2026, 9, 16, 19, 0), "gemini current reset");
    Eq(w[0].Kind, new WindowKind.Session(null), "gemini session has no length");
    Eq(w[0].Label, "현재 한도", "gemini session label");
    Eq(w[1].UsedPercent, 34.0, "gemini weekly %");
    Eq(w[1].ResetsAt, D(2026, 9, 22, 14, 0), "gemini weekly reset");
    Eq(GeminiParse.Plan(page), "PRO", "gemini plan");
    Eq(GeminiParse.Plan("Sign in"), null, "gemini no plan");
    Eq(GeminiParse.Windows("Sign in - Google Accounts", DateTimeOffset.Now, seoul).Count, 0, "gemini not logged in");
    Eq(GeminiParse.ParseReset("7:00 PM", D(2026, 9, 16, 20, 0), seoul), D(2026, 9, 17, 19, 0), "gemini rolls to tomorrow");
    Eq(GeminiParse.ParseReset("Jan 3 at 9:00 AM", D(2026, 12, 30, 10, 0), seoul), D(2027, 1, 3, 9, 0), "gemini new year");
    Eq(GeminiParse.ParseReset("in about 3 hours", DateTimeOffset.Now, seoul), null, "gemini garbage reset");
}

// --- claude.ai 페이지
{
    var page = """
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
    """;
    var now = D(2026, 9, 16, 17, 40);
    var w = ClaudeWebParse.Windows(page, now, seoul);
    Eq(w.Count, 3, "claude web windows (제품별 막대 제외)");
    Eq(w[0].Kind, new WindowKind.Session(5), "claude web session");
    Eq(w[0].UsedPercent, 14.0, "claude web session %");
    Eq(w[0].ResetsAt, D(2026, 9, 16, 21, 10), "claude web session reset");
    Eq(w[1].Kind, new WindowKind.WeeklyAllModels(), "claude web weekly");
    Eq(w[1].ResetsAt, D(2026, 9, 20, 12, 0), "claude web weekly → next Sunday");
    Eq(w[2].Kind, new WindowKind.WeeklyScoped("Fable"), "claude web scoped");
    Eq(ClaudeWebParse.Plan(page), "Max (5x)", "claude web plan");
    Eq(ClaudeWebParse.Windows("로그인하세요", now, seoul).Count, 0, "claude web not logged in");

    var d = D(2026, 9, 16, 10, 0);
    Eq(ClaudeWebParse.ParseReset("오후 9:10에 재설정", d, seoul), D(2026, 9, 16, 21, 10), "PM to 24h");
    Eq(ClaudeWebParse.ParseReset("오후 12:00에 재설정", d, seoul), D(2026, 9, 16, 12, 0), "noon");
    Eq(ClaudeWebParse.ParseReset("오전 12:00에 재설정", D(2026, 9, 16, 22, 0), seoul), D(2026, 9, 17, 0, 0), "midnight");
    Eq(ClaudeWebParse.ParseReset("오후 9:10에 재설정", D(2026, 9, 16, 22, 0), seoul), D(2026, 9, 17, 21, 10), "passed → tomorrow");
    Eq(ClaudeWebParse.ParseReset("재설정: (목) 오전 2:10", D(2026, 9, 16, 22, 54), seoul), D(2026, 9, 17, 2, 10), "short weekday");
    Eq(ClaudeWebParse.ParseReset("재설정: (토) 오후 3:00", d, seoul), D(2026, 9, 19, 15, 0), "short weekday far");
    Eq(ClaudeWebParse.ParseReset("재설정: (일요일) 오후 12:00", now, seoul), D(2026, 9, 20, 12, 0), "full weekday");
    Eq(ClaudeWebParse.ParseReset("토큰 재설정: 오후 3:00", d, seoul), D(2026, 9, 16, 15, 0), "bare char is not weekday");

    var english = """
    Usage
    Max (5x)
    Current session
    Resets at 9:10 PM
    14% used
    Current week
    Resets Sunday at 12:00 PM
    5% used
    """;
    var e = ClaudeWebParse.Windows(english, now, seoul);
    Eq(e.Count, 2, "claude english windows");
    Eq(e[0].UsedPercent, 14.0, "claude english %");
    Eq(e[1].ResetsAt, D(2026, 9, 20, 12, 0), "claude english Sunday");

    var current = """
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
    """;
    var c = ClaudeWebParse.Windows(current, D(2026, 9, 16, 22, 54), seoul);
    Eq(c.Count, 3, "claude current format");
    Eq(c[0].ResetsAt, D(2026, 9, 17, 2, 10), "claude current session reset");
    Eq(c[2].Kind, new WindowKind.WeeklyScoped("Fable"), "claude current scoped");
}

// --- chatgpt.com Codex 페이지
{
    var page = """
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
    """;
    var w = CodexWebParse.Windows(page, D(2026, 9, 16, 19, 0), seoul);
    Eq(w.Count, 2, "codex web windows (차트 눈금 제외)");
    Eq(w[0].Kind, new WindowKind.Session(5), "codex web session");
    Eq(w[1].Kind, new WindowKind.Weekly(), "codex web weekly");
    Eq(w[0].UsedPercent, 0.0, "codex web remaining→used 100");
    Eq(w[1].UsedPercent, 45.0, "codex web remaining→used 55");
    Eq(w[0].ResetsAt, null, "codex web session no reset");
    Eq(w[1].ResetsAt, D(2026, 9, 19, 21, 57), "codex web weekly reset");
    Eq(CodexWebParse.Plan(page), "PLUS", "codex web plan");
    Eq(CodexWebParse.Plan("로그인하세요"), null, "codex web no plan");
    Eq(CodexWebParse.ParseReset("주간 사용 한도", seoul), null, "label is not reset");
    Eq(CodexWebParse.Windows("Log in to ChatGPT", DateTimeOffset.Now, seoul).Count, 0, "codex web not logged in");
}

// --- 표시 로직
{
    var now = D(2026, 9, 16, 17, 0);
    Eq(MostUrgent([U(Provider.Claude, 20, null), U(Provider.Codex, 88, null), U(Provider.Gemini, 45, null)])?.Usage.Provider,
       Provider.Codex, "picks highest");
    var unknown = new ProviderUsage(Provider.Claude, [W(new WindowKind.Session(5), null)], now);
    Eq(MostUrgent([unknown, U(Provider.Codex, 3, null)])?.Usage.Provider, Provider.Codex, "unknown % never wins");
    Eq(MostUrgent([unknown]) == null, true, "only unknown → nil");
    Eq(TrayText([unknown], now), "—", "only unknown → dash");

    var u = new ProviderUsage(Provider.Claude, [W(new WindowKind.Session(5), 11, now.AddSeconds(3 * 3600 + 600))], now);
    Eq(TrayText([u], now), "89% 남음 · 3시간", "remaining not used");
    Eq(TrayText([new ProviderUsage(Provider.Claude, [W(new WindowKind.Session(5), 33.5)], now)], now), "66% 남음", "33.5 rounds like Swift");
    Eq(TrayText([ProviderUsage.Unavailable(Provider.Gemini, "x")], now), "—", "all unavailable");
    Eq(W(new WindowKind.Session(5), 11, now.AddSeconds(3 * 3600 + 600)).Summary(now), "11% · 3시간 후 초기화", "summary");
    Eq(W(new WindowKind.Session(5), 0).Summary(now), "0%", "summary no reset");

    Eq(UpdatedAgo(now.AddSeconds(-30), now), "방금 업데이트됨", "ago now");
    Eq(UpdatedAgo(now.AddMinutes(-14), now), "14분 전에 업데이트됨", "ago 14m");
    Eq(UpdatedAgo(now.AddHours(-3), now), "3시간 전에 업데이트됨", "ago 3h");
    Eq(UpdatedAgo(now.AddDays(-2), now), "2일 전에 업데이트됨", "ago 2d");

    Eq(W(new WindowKind.Session(5), 0, now.AddSeconds(76 * 3600 + 53 * 60)).TimeToReset(now), "3일", "days");
    Eq(W(new WindowKind.Session(5), 0, now.AddSeconds(3 * 3600 + 26 * 60)).TimeToReset(now), "3시간", "hours");
    Eq(W(new WindowKind.Session(5), 0, now.AddMinutes(47)).TimeToReset(now), "47분", "minutes");
    Eq(W(new WindowKind.Session(5), 0, now.AddSeconds(20)).TimeToReset(now), "1분", "at least a minute");
    Eq(W(new WindowKind.Session(5), 0, now.AddSeconds(-60)).TimeToReset(now), null, "past reset");

    Eq(W(new WindowKind.Weekly(), 79.9).Severity, Severity.Normal, "79.9 normal");
    Eq(W(new WindowKind.Weekly(), 80).Severity, Severity.Warning, "80 warning");
    Eq(W(new WindowKind.Weekly(), 95).Severity, Severity.Critical, "95 critical");
    Eq(W(new WindowKind.Weekly(), null).Severity, Severity.Normal, "unknown normal");

    // 세션 기준 선택
    var p1 = MostUrgent([U(Provider.Claude, 23, 9), U(Provider.Codex, 2, 45), U(Provider.Gemini, 0, 0)]);
    Eq(p1?.Usage.Provider, Provider.Claude, "weekly doesn't mask session");
    var p2 = MostUrgent([U(Provider.Claude, 23, 9), U(Provider.Codex, 2, 92)]);
    Eq(p2?.Window.Kind, new WindowKind.Weekly(), "dangerous weekly surfaces");
    Eq(MostUrgent([U(Provider.Claude, 10, 79)])?.Window.Kind, new WindowKind.Session(5), "weekly 79 quiet");
    Eq(MostUrgent([U(Provider.Gemini, null, 30)])?.Window.Kind, new WindowKind.Weekly(), "no session fallback");
    Eq(MostUrgent([U(Provider.Claude, 6, 13), U(Provider.Codex, 100, 62), U(Provider.Gemini, 0, 0)])?.Usage.Provider,
       Provider.Claude, "exhausted yields");
    Eq(TrayText([U(Provider.Claude, 6, 13), U(Provider.Codex, 100, 62)], now), "94% 남음", "exhausted yields text");
    Eq(MostUrgent([U(Provider.Claude, 6, null), U(Provider.Codex, 99.7, null)])?.Usage.Provider, Provider.Claude, "99.7 yields");
    Eq(MostUrgent([U(Provider.Claude, 100, 100), U(Provider.Codex, 100, 100)])?.Window.UsedPercent, 100.0, "all exhausted shows");
    Eq(TrayNumber([U(Provider.Claude, 6, 13)]), 94, "tray number");
    Eq(TrayNumber([]), null, "tray number none");

    var entries = Entries([U(Provider.Claude, 10, 50), U(Provider.Codex, null, 30), ProviderUsage.Unavailable(Provider.Gemini, "x")]);
    Eq(entries.Count, 2, "entries skip unavailable");
    Eq(entries[0].Text, "90%", "entries prefer session");
    Eq(entries[1].Text, "70%", "entries fallback");

    // 리셋 보완
    var r = D(2026, 9, 19, 21, 57);
    Eq(FillingMissingResets([W(new WindowKind.Weekly(), 45)], [W(new WindowKind.Weekly(), 45, r)])[0].ResetsAt, r, "fills reset");
    Eq(FillingMissingResets([W(new WindowKind.Session(5), 4, now)], [W(new WindowKind.Session(5), 99, r)])[0].ResetsAt, now, "keeps web reset");
    Eq(FillingMissingResets([W(new WindowKind.Session(5), 4)], [W(new WindowKind.Weekly(), 45, r)])[0].ResetsAt, null, "no cross-kind");
    Eq(FillingMissingResets([W(new WindowKind.WeeklyScoped("Fable"), 1)],
        [W(new WindowKind.WeeklyScoped("Opus"), 3, now), W(new WindowKind.WeeklyScoped("Fable"), 1, r)])[0].ResetsAt, r, "scoped by model");
    Eq(new WindowKind.Session(5).Id == new WindowKind.Session(3).Id, false, "distinct session ids");
    Eq(new WindowKind.Session(null).Id == new WindowKind.Session(5).Id, false, "null vs 5 ids");

    L10n.IsKorean = false;
    Eq(L10n.Label(new WindowKind.Session(5)), "5-hour limit", "english label");
    Eq(W(new WindowKind.Session(5), 11, now.AddHours(3).AddMinutes(10)).Summary(now), "11% · resets in 3h", "english summary");
    L10n.IsKorean = true;
}

Console.WriteLine($"{checks - failures}/{checks} checks passed");
return failures == 0 ? 0 : 1;
