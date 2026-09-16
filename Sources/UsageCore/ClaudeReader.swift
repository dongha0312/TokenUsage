import Foundation

/// Claude Code는 서버가 내려준 사용량을 `~/.claude.json` 의 `cachedUsageUtilization` 에 캐시한다.
/// `/usage` 화면이 보여주는 바로 그 수치다. 추정할 게 없다.
///
/// 이전에는 JSONL의 토큰을 합치고 429 기록에서 한도를 역산했는데, 실측 대조 결과 2배쯤 빗나갔다
/// (역산 19% vs 실제 10%). 창 시작점도 주간 앵커도 틀렸다. 그 기계 전체를 이 파일 하나로 대체한다.
///
///   "limits": [
///     { "kind": "session",       "percent": 10, "resets_at": "...", "scope": null },
///     { "kind": "weekly_all",    "percent": 5,  "resets_at": "...", "scope": null },
///     { "kind": "weekly_scoped", "percent": 0,  "resets_at": "...",
///       "scope": { "model": { "display_name": "Fable" } } }
///   ]
public enum ClaudeReader {
    public static var defaultConfigPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    // MARK: - 순수 로직

    /// `limits` 배열 하나를 표시용 창으로 바꾼다.
    public static func windows(fromLimits limits: [[String: Any]], now: Date) -> [UsageWindow] {
        limits.compactMap { item in
            guard let percent = number(item["percent"]) else { return nil }
            let resetsAt = (item["resets_at"] as? String).flatMap(parseDate)

            // 리셋 시각이 지났으면 그 창은 이미 비워졌다. 굳은 수치를 현재값처럼 보여주지 않는다.
            if let resetsAt, resetsAt <= now {
                return UsageWindow(kind: kind(for: item), usedPercent: 0, resetsAt: nil)
            }
            return UsageWindow(kind: kind(for: item), usedPercent: percent, resetsAt: resetsAt)
        }
    }

    /// 모델 이름은 서버가 준 display_name을 그대로 쓴다. 코드에 박아두면 새 모델이 나올 때 깨진다.
    static func kind(for item: [String: Any]) -> WindowKind {
        let scopedName = (item["scope"] as? [String: Any])
            .flatMap { $0["model"] as? [String: Any] }
            .flatMap { $0["display_name"] as? String }

        switch item["kind"] as? String {
        case "session": return .session(hours: 5)
        case "weekly_all": return .weeklyAllModels
        case "weekly_scoped": return .weeklyScoped(scopedName ?? "?")
        default:
            if let name = scopedName { return .weeklyScoped(name) }
            return .other((item["kind"] as? String) ?? "limit")
        }
    }

    /// "2026-09-16T12:10:00.293919+00:00" — 소수점 6자리가 온다.
    /// ISO8601DateFormatter는 3자리를 기대하므로 소수부를 잘라내고 다시 시도한다.
    public static func parseDate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }

        // 소수부만 제거해서 마지막으로 시도한다.
        let stripped = s.replacingOccurrences(of: #"\.\d+"#, with: "",
                                              options: .regularExpression)
        return plain.date(from: stripped)
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        default: return nil
        }
    }

    // MARK: - 파일 읽기

    public struct Cached: Sendable {
        public let windows: [UsageWindow]
        public let fetchedAt: Date?
        public let plan: String?
        public init(windows: [UsageWindow], fetchedAt: Date?, plan: String? = nil) {
            self.windows = windows; self.fetchedAt = fetchedAt; self.plan = plan
        }
    }

    /// "claude_max" -> "MAX". 새 플랜이 생겨도 그대로 대문자로 보여주면 된다.
    static func planName(_ organizationType: String?) -> String? {
        guard let t = organizationType, !t.isEmpty else { return nil }
        return t.replacingOccurrences(of: "claude_", with: "").uppercased()
    }

    /// 설정 파일의 캐시 블록을 읽는다. 파싱만 하고 표시 판단은 하지 않는다.
    ///
    /// nil은 "파일 자체를 못 읽었다"는 뜻만 갖는다. 파일은 멀쩡한데 사용량 캐시만 없는 경우는
    /// 빈 windows로 돌려준다 — 안내 문구가 달라야 해서 두 경우를 섞으면 안 된다.
    public static func readCached(configPath: URL = defaultConfigPath, now: Date = Date()) -> Cached? {
        guard let data = try? Data(contentsOf: configPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let plan = planName((root["oauthAccount"] as? [String: Any])?["organizationType"] as? String)

        guard let cache = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cache["utilization"] as? [String: Any]
        else { return Cached(windows: [], fetchedAt: nil, plan: plan) }

        let fetchedAt = number(cache["fetchedAtMs"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        let limits = utilization["limits"] as? [[String: Any]] ?? []
        return Cached(windows: windows(fromLimits: limits, now: now), fetchedAt: fetchedAt, plan: plan)
    }

    public static func read(configPath: URL = defaultConfigPath, now: Date = Date()) -> ProviderUsage {
        guard let cached = readCached(configPath: configPath, now: now) else {
            return .unavailable(.claude, L10n.configUnreadable)
        }
        guard !cached.windows.isEmpty else {
            return .unavailable(.claude, L10n.noUsageCache)
        }

        // 이 캐시는 Claude Code에서 /usage 를 실행할 때 갱신된다. 일반 사용만으로는 안 바뀐다.
        // 그래서 언제 기준인지를 항상 같이 보여준다 (UI의 "N분 전에 업데이트됨").
        return ProviderUsage(provider: .claude, windows: cached.windows,
                             updatedAt: cached.fetchedAt, plan: cached.plan)
    }
}
