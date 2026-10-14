// UsageCore(Swift)를 그대로 옮긴 것. 판단 규칙과 파서는 macOS 판과 같아야 한다.
// 바꿀 때는 Sources/UsageCore 쪽과 같이 바꾼다. 주석의 "왜"는 거기 원본에 더 길게 있다.
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace TokenUsage;

public enum Provider { Claude, Codex, Gemini }

/// 창의 종류. 파서는 벤더 문구가 아니라 의미를 넘긴다.
public abstract record WindowKind
{
    /// 길이를 공개하지 않는 벤더(Gemini)는 Hours가 null이다. 5를 넣으면 거짓말이 된다.
    public sealed record Session(int? Hours) : WindowKind;
    public sealed record Weekly : WindowKind;
    public sealed record WeeklyAllModels : WindowKind;
    public sealed record WeeklyScoped(string Model) : WindowKind;
    public sealed record Other(string Raw) : WindowKind;

    public bool IsSession => this is Session;

    public string Id => this switch
    {
        Session s => $"session:{(s.Hours?.ToString() ?? "-")}",
        Weekly => "weekly",
        WeeklyAllModels => "weekly:all",
        WeeklyScoped w => $"weekly:{w.Model}",
        Other o => $"other:{o.Raw}",
        _ => "?",
    };
}

public enum Severity { Normal, Warning, Critical }

/// 한도 창 하나. 비율은 **사용한 쪽**을 담는다.
public sealed record UsageWindow
{
    public WindowKind Kind { get; }
    public double? UsedPercent { get; }
    public DateTimeOffset? ResetsAt { get; }

    public UsageWindow(WindowKind kind, double? usedPercent, DateTimeOffset? resetsAt)
    {
        Kind = kind;
        UsedPercent = usedPercent is double p ? Math.Clamp(p, 0, 100) : null;
        ResetsAt = resetsAt;
    }

    public string? TimeToReset(DateTimeOffset now)
    {
        if (ResetsAt is not DateTimeOffset r || r <= now) return null;
        var secs = (int)(r - now).TotalSeconds;
        if (secs >= 86400) return L10n.Days(secs / 86400);
        if (secs >= 3600) return L10n.Hours(secs / 3600);
        return L10n.Minutes(Math.Max(secs / 60, 1));
    }

    public string Summary(DateTimeOffset now)
    {
        var head = UsedPercent is double u ? $"{Usage.Round(u)}%" : "—";
        return TimeToReset(now) is string t ? L10n.ResetsIn(head, t) : head;
    }

    public string Label => L10n.Label(Kind);

    public Severity Severity => (UsedPercent ?? 0) switch
    {
        >= 95 => Severity.Critical,
        >= 80 => Severity.Warning,
        _ => Severity.Normal,
    };
}

public sealed record ProviderUsage(Provider Provider, IReadOnlyList<UsageWindow> Windows,
                                   DateTimeOffset? UpdatedAt, string? Plan = null, string? Note = null)
{
    public static ProviderUsage Unavailable(Provider p, string note) => new(p, [], null, null, note);
}

public static class Usage
{
    /// Swift의 rounded()는 0.5를 바깥으로 올린다. C# 기본값(은행가 반올림)을 쓰면 33.5%가 어긋난다.
    public static int Round(double v) => (int)Math.Round(v, MidpointRounding.AwayFromZero);

    /// 메뉴바에 올릴 하나. 세션 창 기준, 주간은 경고 이상일 때만, 다 쓴 창은 다른 데 여유가 있으면 뺀다.
    public static (ProviderUsage Usage, UsageWindow Window)? MostUrgent(IEnumerable<ProviderUsage> usages)
    {
        var all = usages.SelectMany(u => u.Windows.Select(w => (u, w)))
                        .Where(x => x.w.UsedPercent != null).ToList();
        var sessions = all.Where(x => x.w.Kind.IsSession).ToList();
        var urgentOthers = all.Where(x => !x.w.Kind.IsSession && x.w.Severity != Severity.Normal);
        var pool = sessions.Count == 0 ? all : sessions.Concat(urgentOthers).ToList();
        if (pool.Count == 0) return null;
        var withRoom = pool.Where(x => Round(x.w.UsedPercent ?? 0) < 100).ToList();
        var best = (withRoom.Count == 0 ? pool : withRoom).MaxBy(x => x.w.UsedPercent ?? 0);
        return (best.u, best.w);
    }

    static string Remaining(double used) => $"{100 - Round(used)}%";

    public static string TrayText(IEnumerable<ProviderUsage> usages, DateTimeOffset now)
    {
        if (MostUrgent(usages) is not var (_, w) || w.UsedPercent is not double used) return "—";
        var pct = L10n.Left(Remaining(used));
        return w.TimeToReset(now) is string t ? $"{pct} · {t}" : pct;
    }

    /// 트레이 아이콘에 그릴 남은 비율 숫자. 없으면 null.
    public static int? TrayNumber(IEnumerable<ProviderUsage> usages) =>
        MostUrgent(usages) is var (_, w) && w.UsedPercent is double u ? 100 - Round(u) : null;

    /// 제공자별 남은 비율 (툴팁용). 제공자 안에서도 세션을 우선한다.
    public static List<(Provider Provider, string Text)> Entries(IEnumerable<ProviderUsage> usages)
    {
        var result = new List<(Provider, string)>();
        foreach (var u in usages)
        {
            var sessions = u.Windows.Where(w => w.Kind.IsSession && w.UsedPercent != null).ToList();
            var pool = sessions.Count > 0 ? sessions : u.Windows.Where(w => w.UsedPercent != null).ToList();
            if (pool.MaxBy(w => w.UsedPercent ?? 0)?.UsedPercent is double used)
                result.Add((u.Provider, Remaining(used)));
        }
        return result;
    }

    public static string? UpdatedAgo(DateTimeOffset? updatedAt, DateTimeOffset now)
    {
        if (updatedAt is not DateTimeOffset at) return null;
        var secs = (int)(now - at).TotalSeconds;
        if (secs < 60) return L10n.UpdatedJustNow;
        if (secs < 3600) return L10n.UpdatedAgo(L10n.Minutes(secs / 60));
        if (secs < 86400) return L10n.UpdatedAgo(L10n.Hours(secs / 3600));
        return L10n.UpdatedAgo(L10n.Days(secs / 86400));
    }

    /// 웹이 리셋 시각을 못 읽은 창은 로컬 기록에서 같은 종류의 시각을 빌려온다.
    public static List<UsageWindow> FillingMissingResets(IEnumerable<UsageWindow> windows,
                                                         IReadOnlyList<UsageWindow> local)
    {
        var byKind = new Dictionary<string, UsageWindow>();
        foreach (var w in local) byKind.TryAdd(w.Kind.Id, w);
        return windows.Select(w =>
            w.ResetsAt == null && byKind.TryGetValue(w.Kind.Id, out var m) && m.ResetsAt != null
                ? new UsageWindow(w.Kind, w.UsedPercent, m.ResetsAt) : w).ToList();
    }

    // MARK: 시간 계산 공통

    /// tz 기준 벽시계 시각을 절대 시각으로.
    public static DateTimeOffset At(TimeZoneInfo tz, DateTime day, int hour, int minute)
    {
        var local = new DateTime(day.Year, day.Month, day.Day, hour, minute, 0, DateTimeKind.Unspecified);
        return new DateTimeOffset(local, tz.GetUtcOffset(local));
    }

    /// 오늘 그 시각, 이미 지났으면 내일.
    public static DateTimeOffset TodayOrTomorrow(TimeZoneInfo tz, DateTimeOffset now, int hour, int minute)
    {
        var today = TimeZoneInfo.ConvertTime(now, tz).Date;
        var d = At(tz, today, hour, minute);
        return d <= now ? At(tz, today.AddDays(1), hour, minute) : d;
    }

    public static List<string> CleanLines(string text) =>
        Regex.Split(text, @"\r\n|[\n\r\v\f\u0085  ]")
             .Select(l => l.Trim()).Where(l => l.Length > 0).ToList();

    public static double? Num(JsonNode? n)
    {
        try { return n?.GetValue<double>(); } catch { return null; }
    }

    public static double ParseDouble(string s) => double.Parse(s, CultureInfo.InvariantCulture);
}

// MARK: - claude.ai/settings/usage

public static class ClaudeWebParse
{
    public static bool IsLoaded(string text) =>
        text.Contains("사용됨") || text.Contains("% used", StringComparison.OrdinalIgnoreCase);

    public static WindowKind Kind(string label)
    {
        switch (label)
        {
            case "현재 세션" or "Current session": return new WindowKind.Session(5);
            case "이번 주" or "Current week": return new WindowKind.WeeklyAllModels();
        }
        var model = label.Split(' ').Last();
        return label != model ? new WindowKind.WeeklyScoped(model.Trim('(', ')')) : new WindowKind.Other(label);
    }

    public static string? Plan(string text)
    {
        string[] titles = ["사용량", "Usage"];
        var lines = Usage.CleanLines(text);
        for (var i = 0; i + 1 < lines.Count; i++)
        {
            if (!titles.Contains(lines[i])) continue;
            var c = lines[i + 1];
            if (!titles.Contains(c) && c.Length <= 20 && c.Any(char.IsLetter) && !c.Contains("사용")) return c;
        }
        return null;
    }

    public static List<UsageWindow> Windows(string text, DateTimeOffset now, TimeZoneInfo tz)
    {
        if (!IsLoaded(text)) return [];
        var lines = Usage.CleanLines(text);
        var result = new List<UsageWindow>();
        // "N% 사용됨"을 기준점으로 앞의 두 줄을 재설정·라벨로 읽는다.
        for (var i = 2; i < lines.Count; i++)
        {
            if (UsedPercent(lines[i]) is not double p) continue;
            result.Add(new UsageWindow(Kind(lines[i - 2]), p, ParseReset(lines[i - 1], now, tz)));
        }
        return result;
    }

    static readonly Regex UsedRe = new(@"^([0-9]+(?:\.[0-9]+)?)\s*%\s*(사용됨|used)$", RegexOptions.IgnoreCase);
    static double? UsedPercent(string line) =>
        UsedRe.Match(line) is { Success: true } m ? Usage.ParseDouble(m.Groups[1].Value) : null;

    /// "오후 9:10에 재설정" · "(일요일) 오후 12:00에 재설정" · "Resets at 9:10 PM"
    public static DateTimeOffset? ParseReset(string line, DateTimeOffset now, TimeZoneInfo tz)
    {
        if (Clock(line) is not var (hour, minute)) return null;
        if (Weekday(line) is DayOfWeek wd)
        {
            // 지금 이후로 처음 오는 그 요일 그 시각.
            var today = TimeZoneInfo.ConvertTime(now, tz).Date;
            for (var i = 0; i <= 7; i++)
            {
                var day = today.AddDays(i);
                if (day.DayOfWeek != wd) continue;
                var d = Usage.At(tz, day, hour, minute);
                if (d > now) return d;
            }
            return null;
        }
        return Usage.TodayOrTomorrow(tz, now, hour, minute);
    }

    static readonly Regex ClockRe = new(@"(오전|오후|AM|PM)?\s*([0-9]{1,2}):([0-9]{2})\s*(AM|PM)?", RegexOptions.IgnoreCase);

    public static (int Hour, int Minute)? Clock(string line)
    {
        var m = ClockRe.Match(line);
        if (!m.Success) return null;
        var hour = int.Parse(m.Groups[2].Value);
        var minute = int.Parse(m.Groups[3].Value);
        var marker = (m.Groups[1].Success ? m.Groups[1].Value : m.Groups[4].Value).ToUpperInvariant();
        if (marker is "오후" or "PM" && hour < 12) hour += 12;
        if (marker is "오전" or "AM" && hour == 12) hour = 0;
        if (hour is < 0 or > 23 || minute is < 0 or > 59) return null;
        return (hour, minute);
    }

    static readonly (string, DayOfWeek)[] KoreanDays =
        [("일요일", DayOfWeek.Sunday), ("월요일", DayOfWeek.Monday), ("화요일", DayOfWeek.Tuesday),
         ("수요일", DayOfWeek.Wednesday), ("목요일", DayOfWeek.Thursday), ("금요일", DayOfWeek.Friday),
         ("토요일", DayOfWeek.Saturday)];

    public static DayOfWeek? Weekday(string line)
    {
        foreach (var (name, d) in KoreanDays) if (line.Contains(name)) return d;
        // 축약형 "(목)". 한 글자라 괄호로 감싼 것만 받는다 ("토큰"의 "토"를 토요일로 읽지 않게).
        foreach (var (name, d) in KoreanDays) if (line.Contains($"({name[0]})")) return d;
        foreach (var d in Enum.GetValues<DayOfWeek>())
            if (line.Contains(d.ToString(), StringComparison.OrdinalIgnoreCase)) return d;
        return null;
    }
}

// MARK: - chatgpt.com/codex/cloud/settings/analytics#usage

public static class CodexWebParse
{
    public static bool IsLoaded(string text) =>
        text.Contains("사용 한도") || text.Contains("usage limit", StringComparison.OrdinalIgnoreCase);

    static readonly string[] RemainingWords = ["남음", "left", "remaining"];
    static readonly string[] KnownPlans = ["FREE", "PLUS", "PRO", "BUSINESS", "ENTERPRISE", "TEAM", "GO"];

    public static string? Plan(string text) =>
        Usage.CleanLines(text).Take(20).FirstOrDefault(KnownPlans.Contains);

    public static WindowKind Kind(string label)
    {
        var l = label.ToLowerInvariant();
        if (label.Contains("5시간") || l.Contains("5-hour") || l.Contains("5 hour")) return new WindowKind.Session(5);
        if (label.Contains("주간") || l.Contains("weekly") || l.Contains("week")) return new WindowKind.Weekly();
        return new WindowKind.Other(label);
    }

    public static List<UsageWindow> Windows(string text, DateTimeOffset now, TimeZoneInfo tz)
    {
        if (!IsLoaded(text)) return [];
        var lines = Usage.CleanLines(text);
        var result = new List<UsageWindow>();
        // 차트 축 눈금(0%/100%)과 구분하려고 "남음"이 바로 뒤에 오는 퍼센트만 본다.
        for (var i = 1; i + 1 < lines.Count; i++)
        {
            if (BarePercent(lines[i]) is not double remaining) continue;
            if (!RemainingWords.Any(w => string.Equals(lines[i + 1], w, StringComparison.OrdinalIgnoreCase))) continue;
            var resetLine = i + 2 < lines.Count ? lines[i + 2] : "";
            // 페이지는 남은 비율을 보여준다. 앱은 사용률 기준이라 뒤집는다.
            result.Add(new UsageWindow(Kind(lines[i - 1]), 100 - remaining, ParseReset(resetLine, tz)));
        }
        return result;
    }

    static readonly Regex BareRe = new(@"^([0-9]+(?:\.[0-9]+)?)\s*%$");
    static double? BarePercent(string line) =>
        BareRe.Match(line) is { Success: true } m ? Usage.ParseDouble(m.Groups[1].Value) : null;

    static readonly Regex ResetRe = new(@"(\d{4})\.\s*(\d{1,2})\.\s*(\d{1,2})\.\s*(오전|오후)?\s*(\d{1,2}):(\d{2})");

    /// "2026. 9. 19. 오후 9:57 초기화"
    public static DateTimeOffset? ParseReset(string line, TimeZoneInfo tz)
    {
        if (!line.Contains("초기화") && !line.Contains("reset", StringComparison.OrdinalIgnoreCase)) return null;
        var m = ResetRe.Match(line);
        if (!m.Success) return null;
        int G(int i) => int.Parse(m.Groups[i].Value);
        var hour = G(5);
        if (m.Groups[4].Value == "오후" && hour < 12) hour += 12;
        if (m.Groups[4].Value == "오전" && hour == 12) hour = 0;
        try { return Usage.At(tz, new DateTime(G(1), G(2), G(3)), hour, G(6)); }
        catch (ArgumentOutOfRangeException) { return null; }
    }
}

// MARK: - gemini.google.com/usage

public static class GeminiParse
{
    public const string Sentinel = "Usage limits";

    public static bool IsLoaded(string text) => text.Contains(Sentinel);

    public static string? Plan(string text)
    {
        var i = text.IndexOf(Sentinel, StringComparison.Ordinal);
        if (i < 0) return null;
        var after = text.Substring(i + Sentinel.Length, Math.Min(40, text.Length - i - Sentinel.Length));
        return Usage.CleanLines(after).FirstOrDefault(s =>
            s.Length <= 12 && s == s.ToUpperInvariant() && char.IsLetter(s[0]));
    }

    public static List<UsageWindow> Windows(string text, DateTimeOffset now, TimeZoneInfo tz)
    {
        if (!IsLoaded(text)) return [];
        // "Weekly limit"으로 두 섹션을 자른다. 섹션 안에서는 %와 Resets 순서를 따지지 않는다.
        var parts = text.Split("Weekly limit");
        var result = new List<UsageWindow>();
        if (Window(new WindowKind.Session(null), parts[0], now, tz) is UsageWindow s) result.Add(s);
        if (parts.Length > 1 && Window(new WindowKind.Weekly(), parts[1], now, tz) is UsageWindow w) result.Add(w);
        return result;
    }

    static readonly Regex UsedRe = new(@"([0-9]+(?:\.[0-9]+)?)\s*%\s*used", RegexOptions.IgnoreCase);
    static readonly Regex ResetsRe = new(@"Resets\s+(?:at\s+)?([^\n]+)", RegexOptions.IgnoreCase);

    static UsageWindow? Window(WindowKind kind, string section, DateTimeOffset now, TimeZoneInfo tz)
    {
        var m = UsedRe.Match(section);
        if (!m.Success) return null;
        var r = ResetsRe.Match(section);
        return new UsageWindow(kind, Usage.ParseDouble(m.Groups[1].Value),
                               r.Success ? ParseReset(r.Groups[1].Value, now, tz) : null);
    }

    /// "7:00 PM" 또는 "Sep 22 at 2:00 PM"
    public static DateTimeOffset? ParseReset(string raw, DateTimeOffset now, TimeZoneInfo tz)
    {
        var s = raw.Trim();
        var inv = CultureInfo.InvariantCulture;
        if (DateTime.TryParseExact(s, "h:mm tt", inv, DateTimeStyles.None, out var t))
            return Usage.TodayOrTomorrow(tz, now, t.Hour, t.Minute);

        // 연도가 없으니 올해로 두고, 하루 넘게 과거로 계산되면 내년으로 넘긴다.
        if (!DateTime.TryParseExact(s, "MMM d 'at' h:mm tt", inv, DateTimeStyles.None, out var dt)) return null;
        var year = TimeZoneInfo.ConvertTime(now, tz).Year;
        var d = Usage.At(tz, new DateTime(year, dt.Month, dt.Day), dt.Hour, dt.Minute);
        return d < now.AddDays(-1) ? Usage.At(tz, new DateTime(year + 1, dt.Month, dt.Day), dt.Hour, dt.Minute) : d;
    }
}

// MARK: - 로컬 폴백: ~/.claude.json, ~/.codex/sessions

public static class ClaudeReader
{
    public static string DefaultConfigPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude.json");

    public static List<UsageWindow> Windows(JsonArray limits, DateTimeOffset now)
    {
        var result = new List<UsageWindow>();
        foreach (var item in limits)
        {
            if (Usage.Num(item?["percent"]) is not double percent) continue;
            var resetsAt = ParseDate(item?["resets_at"]?.GetValue<string>());
            var kind = Kind(item!);
            // 리셋 시각이 지났으면 그 창은 이미 비워졌다. 굳은 수치를 현재값처럼 보여주지 않는다.
            result.Add(resetsAt is DateTimeOffset r && r <= now
                ? new UsageWindow(kind, 0, null) : new UsageWindow(kind, percent, resetsAt));
        }
        return result;
    }

    static WindowKind Kind(JsonNode item)
    {
        var scoped = item["scope"]?["model"]?["display_name"]?.GetValue<string>();
        var kind = item["kind"]?.GetValue<string>();
        return kind switch
        {
            "session" => new WindowKind.Session(5),
            "weekly_all" => new WindowKind.WeeklyAllModels(),
            "weekly_scoped" => new WindowKind.WeeklyScoped(scoped ?? "?"),
            _ => scoped != null ? new WindowKind.WeeklyScoped(scoped) : new WindowKind.Other(kind ?? "limit"),
        };
    }

    /// ISO 8601만 받는다. DateTimeOffset.TryParse 혼자 두면 "9/16/2026" 같은 것도 통과시킨다.
    public static DateTimeOffset? ParseDate(string? s) =>
        s != null && Regex.IsMatch(s, @"^\d{4}-\d{2}-\d{2}T")
            && DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d : null;

    public static ProviderUsage Read(DateTimeOffset now, string? path = null)
    {
        JsonNode? root;
        try { root = JsonNode.Parse(File.ReadAllText(path ?? DefaultConfigPath)); }
        catch { return ProviderUsage.Unavailable(Provider.Claude, L10n.ConfigUnreadable); }

        var org = root?["oauthAccount"]?["organizationType"]?.GetValue<string>();
        var plan = string.IsNullOrEmpty(org) ? null : org.Replace("claude_", "").ToUpperInvariant();
        var cache = root?["cachedUsageUtilization"];
        if (cache?["utilization"]?["limits"] is not JsonArray limits)
            return ProviderUsage.Unavailable(Provider.Claude, L10n.NoUsageCache);
        var windows = Windows(limits, now);
        if (windows.Count == 0) return ProviderUsage.Unavailable(Provider.Claude, L10n.NoUsageCache);
        var fetchedAt = Usage.Num(cache["fetchedAtMs"]) is double ms
            ? DateTimeOffset.FromUnixTimeMilliseconds((long)ms) : (DateTimeOffset?)null;
        return new ProviderUsage(Provider.Claude, windows, fetchedAt, plan);
    }
}

public static class CodexReader
{
    public static string DefaultSessionsDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "sessions");

    const int TailBytes = 1 << 20;

    public static List<UsageWindow> Windows(JsonNode rateLimits, DateTimeOffset now)
    {
        var result = new List<UsageWindow>();
        foreach (var key in new[] { "primary", "secondary" })
        {
            var w = rateLimits[key];
            if (Usage.Num(w?["used_percent"]) is not double used) continue;
            var kind = Kind((int)(Usage.Num(w!["window_minutes"]) ?? 0));
            var resetsAt = Usage.Num(w["resets_at"]) is double secs
                ? DateTimeOffset.FromUnixTimeSeconds((long)secs) : (DateTimeOffset?)null;
            // 리셋이 지났으면 비워진 창이다. Codex 창은 다음 사용부터 시작하므로 리셋 시각도 비운다.
            result.Add(resetsAt is DateTimeOffset r && r <= now
                ? new UsageWindow(kind, 0, null) : new UsageWindow(kind, used, resetsAt));
        }
        return result;
    }

    public static WindowKind Kind(int minutes) => minutes switch
    {
        300 => new WindowKind.Session(5),
        10080 => new WindowKind.Weekly(),
        >= 1 and < 1440 => new WindowKind.Session(minutes / 60),
        > 0 => new WindowKind.Other(L10n.Days(minutes / 1440)),
        _ => new WindowKind.Other("limit"),
    };

    static (JsonNode Limits, DateTimeOffset? RecordedAt)? LastRateLimits(string path)
    {
        byte[] data;
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            fs.Seek(Math.Max(0, fs.Length - TailBytes), SeekOrigin.Begin);
            data = new byte[fs.Length - fs.Position];
            fs.ReadExactly(data);
        }
        catch { return null; }

        foreach (var line in Encoding.UTF8.GetString(data).Split('\n').Reverse())
        {
            if (!line.Contains("\"rate_limits\":")) continue;
            try
            {
                var obj = JsonNode.Parse(line);
                if (obj?["payload"]?["rate_limits"] is JsonObject limits)
                    return (limits, ClaudeReader.ParseDate(obj["timestamp"]?.GetValue<string>()));
            }
            catch { }
        }
        return null;
    }

    public static ProviderUsage Read(DateTimeOffset now, string? dir = null)
    {
        dir ??= DefaultSessionsDir;
        if (!Directory.Exists(dir)) return ProviderUsage.Unavailable(Provider.Codex, L10n.NoSessionLogs);
        var recent = new DirectoryInfo(dir).EnumerateFiles("*.jsonl", SearchOption.AllDirectories)
            .OrderByDescending(f => f.LastWriteTimeUtc).Take(5);
        foreach (var f in recent)
        {
            if (LastRateLimits(f.FullName) is not var (limits, recordedAt)) continue;
            var ws = Windows(limits, now);
            if (ws.Count == 0) continue;
            var plan = (limits["plan_type"] as JsonValue)?.TryGetValue<string>(out var p) == true && p.Length > 0
                ? p.ToUpperInvariant() : null;
            return new ProviderUsage(Provider.Codex, ws, recordedAt, plan);
        }
        return ProviderUsage.Unavailable(Provider.Codex, L10n.NoUsageRecord);
    }
}

// MARK: - 문자열 (한국어·영어, 시스템 언어를 따른다)

public static class L10n
{
    public static bool IsKorean = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ko";
    static string Pick(string ko, string en) => IsKorean ? ko : en;

    public static string Label(WindowKind kind) => kind switch
    {
        WindowKind.Session { Hours: null } => Pick("현재 한도", "Current limit"),
        WindowKind.Session s => Pick($"{s.Hours}시간 한도", $"{s.Hours}-hour limit"),
        WindowKind.Weekly => Pick("주간 한도", "Weekly limit"),
        WindowKind.WeeklyAllModels => Pick("주간 · 모든 모델", "Weekly · all models"),
        WindowKind.WeeklyScoped w => Pick($"주간 · {w.Model}", $"Weekly · {w.Model}"),
        WindowKind.Other o => o.Raw,
        _ => "?",
    };

    public static string Days(int n) => Pick($"{n}일", $"{n}d");
    public static string Hours(int n) => Pick($"{n}시간", $"{n}h");
    public static string Minutes(int n) => Pick($"{n}분", $"{n}m");
    public static string ResetsIn(string head, string time) => Pick($"{head} · {time} 후 초기화", $"{head} · resets in {time}");
    public static string UpdatedJustNow => Pick("방금 업데이트됨", "updated just now");
    public static string UpdatedAgo(string t) => Pick($"{t} 전에 업데이트됨", $"updated {t} ago");
    public static string Left(string pct) => Pick($"{pct} 남음", $"{pct} left");

    public static string LoginNeeded(string host) => Pick($"{host} 로그인 필요", $"sign in to {host}");
    public static string ShowingLocal => Pick("로컬 값 표시 중", "showing local data");
    public static string FetchFailed => Pick("웹 조회 실패", "fetch failed");
    public static string PageChanged => Pick("수치를 못 읽음 — 페이지 구조가 바뀐 듯", "couldn't read values — page layout may have changed");
    public static string PageUnreadable(string host) => Pick($"페이지를 못 읽음 · {host}", $"couldn't load page · {host}");
    public static string NoUsageCache => Pick("사용량 캐시 없음 — Claude Code에서 /usage 실행", "no usage cache — run /usage in Claude Code");
    public static string ConfigUnreadable => Pick("~/.claude.json 을 읽지 못함", "couldn't read ~/.claude.json");
    public static string NoSessionLogs => Pick("세션 로그 없음", "no session logs");
    public static string NoUsageRecord => Pick("사용량 기록 없음", "no usage records");

    public static string Refresh => Pick("새로 고침", "Refresh");
    public static string Refreshing => Pick("갱신 중…", "Refreshing…");
    public static string Quit => Pick("종료", "Quit");
    public static string LaunchAtLogin => Pick("Windows 시작 시 실행", "Start with Windows");
    public static string SignIn(string name) => Pick($"{name} 로그인", $"Sign in to {name}");
    public static string OpenUsagePage => Pick("사용량 페이지 열기", "Open usage page");
    public static string RefreshEvery => Pick("갱신 주기", "Refresh every");
    public static string NotifyNearLimit => Pick("한도 임박 시 알림", "Notify when near limit");
    public static string NotificationsOnTitle => Pick("알림을 켰습니다", "Notifications on");
    public static string NotificationsOnBody => Pick("한도의 80%를 넘으면 알려드립니다.", "You'll be notified when a limit passes 80%.");
    public static string Checking(string name) => Pick($"{name} 확인 중", $"Checking {name}");
    public static string WebView2Missing => Pick(
        "Microsoft Edge WebView2 런타임이 필요합니다. 설치 페이지를 열까요?",
        "TokenUsage needs the Microsoft Edge WebView2 Runtime. Open the download page?");
    public static string NearLimitTitle(string p) => Pick($"{p} 한도 임박", $"{p} near limit");
    public static string NearLimitBody(string label, int percent, string? reset)
    {
        var head = Pick($"{label} {percent}% 사용", $"{label} at {percent}%");
        return reset == null ? head : Pick($"{head} · {reset} 후 초기화", $"{head} · resets in {reset}");
    }
}
