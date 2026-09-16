import XCTest
@testable import UsageCore

/// 실제 디스크의 파일로 리더를 돌린다.
/// 단위 테스트는 내가 만든 샘플만 검증하므로, 진짜 포맷과 어긋나는 건 여기서만 잡힌다.
/// 파일이 없는 환경에서는 건너뛴다.
final class RealDataTests: XCTestCase {

    func testClaudeReadsRealUsageCache() throws {
        let path = ClaudeReader.defaultConfigPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path.path), "~/.claude.json 없음")

        let usage = ClaudeReader.read()
        print("[Claude] 플랜=\(usage.plan ?? "-") · \(updatedAgo(usage.updatedAt) ?? "시각 미상")")
        for w in usage.windows { print("  \(w.label)  —  \(w.summary())") }
        XCTAssertFalse(usage.windows.isEmpty, "cachedUsageUtilization을 못 읽었다")
        // /usage 화면과 같은 세 줄이 나와야 한다
        XCTAssertTrue(usage.windows.contains { if case .session = $0.kind { return true }; return false })
        XCTAssertTrue(usage.windows.contains { $0.kind == .weeklyAllModels })
        XCTAssertTrue(usage.windows.contains { if case .weeklyScoped = $0.kind { return true }; return false })
    }

    /// 캐시가 얼마나 신선한지 눈으로 본다. Claude Code가 스스로 갱신하는지 확인하는 용도.
    func testClaudeCacheFreshness() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ClaudeReader.defaultConfigPath.path),
                          "~/.claude.json 없음")
        guard let cached = ClaudeReader.readCached(), let fetchedAt = cached.fetchedAt else {
            throw XCTSkip("fetchedAtMs 없음")
        }
        let age = Date().timeIntervalSince(fetchedAt)
        print("[Claude] 캐시 신선도: \(String(format: "%.1f", age / 60))분 전")
        XCTAssertGreaterThan(age, -60, "미래 시각이면 파싱이 잘못된 것")
    }

    func testCodexReadsRealRateLimits() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: CodexReader.defaultSessionsDir.path),
                          "Codex 로그 없음")
        let usage = CodexReader.read()
        print("[Codex] 플랜=\(usage.plan ?? "-") · \(updatedAgo(usage.updatedAt) ?? "시각 미상")")
        for w in usage.windows { print("  \(w.label)  —  \(w.summary())") }
        XCTAssertNil(usage.note)
        XCTAssertFalse(usage.windows.isEmpty)
        // window_minutes를 못 읽으면 라벨이 "한도"로 떨어진다. 실제 포맷 회귀를 여기서 잡는다.
        XCTAssertFalse(usage.windows.contains { $0.label == "한도" }, "window_minutes 파싱 실패")
    }

    func testMenuBarStringFromRealData() {
        let now = Date()
        let usages = [ClaudeReader.read(now: now), CodexReader.read(now: now)]
        let text = menuBarText(for: usages, now: now)
        print("[메뉴바] \"\(text)\"")
        XCTAssertNotEqual(text, "—")
        XCTAssertFalse(text.contains("nan"))
    }
}
