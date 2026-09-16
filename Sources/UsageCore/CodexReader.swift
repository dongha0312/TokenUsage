import Foundation

/// Codex(ChatGPT)는 매 턴 rate_limits를 세션 로그에 그대로 적어둔다.
/// 추정할 게 없다. OpenAI가 내려준 used_percent와 resets_at을 그냥 읽으면 된다.
///
///   payload.rate_limits.primary   = 5시간 창  (window_minutes: 300)
///   payload.rate_limits.secondary = 주간 창   (window_minutes: 10080)
public enum CodexReader {
    public static var defaultSessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    /// 파일 끝에서 이만큼만 읽어서 마지막 rate_limits를 찾는다. 세션 파일이 커도 싸게 끝난다.
    private static let tailBytes = 1 << 20

    /// JSON 숫자가 Int로 올지 Double로 올지 단정하지 않는다.
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        default: return nil
        }
    }

    public static func windows(from rateLimits: [String: Any], now: Date = Date()) -> [UsageWindow] {
        ["primary", "secondary"].compactMap { key -> UsageWindow? in
            guard let w = rateLimits[key] as? [String: Any],
                  let used = number(w["used_percent"]) else { return nil }
            let minutes = Int(number(w["window_minutes"]) ?? 0)
            let resetsAt = number(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }

            // 이 기록은 Codex를 마지막으로 돌린 시점의 스냅샷이다.
            // 리셋 시각이 이미 지났다면 그 창은 비워졌고, 그 뒤로 쓴 적이 없다는 뜻이다.
            // 굳은 수치를 현재값인 양 보여주면 안 된다.
            //
            // 다음 리셋 시각은 일부러 비운다. Codex의 창은 고정 격자가 아니라
            // 다음 사용 시점부터 시작하므로, 안 쓰고 있는 동안은 예정된 리셋이 없다.
            if let resetsAt, resetsAt <= now {
                return UsageWindow(kind: kind(forMinutes: minutes), usedPercent: 0, resetsAt: nil)
            }
            return UsageWindow(kind: kind(forMinutes: minutes), usedPercent: used, resetsAt: resetsAt)
        }
    }

    public static func kind(forMinutes m: Int) -> WindowKind {
        switch m {
        case 300: return .session(hours: 5)
        case 10080: return .weekly
        case 1..<1440: return .session(hours: m / 60)
        default: return m > 0 ? .other(L10n.days(m / 1440)) : .other("limit")
        }
    }

    /// 파일 뒤쪽부터 훑어 가장 최근 rate_limits를 뽑는다.
    /// 기록 시각도 같이 돌려준다 — 이 수치가 언제 기준인지 밝혀야 하기 때문이다.
    static func lastRateLimits(in url: URL) -> (limits: [String: Any], recordedAt: Date?)? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return nil }

        let marker = Data(#""rate_limits":"#.utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            let line = Data(line)
            guard line.range(of: marker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any]
            else { continue }
            let recordedAt = (obj["timestamp"] as? String).flatMap(ClaudeReader.parseDate)
            return (limits, recordedAt)
        }
        return nil
    }

    /// "plus" -> "PLUS"
    static func planName(_ raw: Any?) -> String? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        return s.uppercased()
    }

    public static func read(sessionsDir: URL = defaultSessionsDir, now: Date = Date()) -> ProviderUsage {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sessionsDir,
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else {
            return .unavailable(.codex, L10n.noSessionLogs)
        }

        var files: [(URL, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            files.append((url, m ?? .distantPast))
        }
        // 최근 파일 몇 개만 본다. 마지막 세션이 rate_limits 없이 끝났을 수 있어서 여유를 둔다.
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            if let found = lastRateLimits(in: url) {
                let ws = windows(from: found.limits, now: now)
                if !ws.isEmpty {
                    return ProviderUsage(provider: .codex, windows: ws,
                                         updatedAt: found.recordedAt,
                                         plan: planName(found.limits["plan_type"]))
                }
            }
        }
        return .unavailable(.codex, L10n.noUsageRecord)
    }
}
