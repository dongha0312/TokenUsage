import AppKit
import Foundation
import SwiftUI
import UsageCore

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var usages: [ProviderUsage] = []
    @Published var loginItemEnabled = LoginItem.isEnabled
    @Published private(set) var loginItemNeedsApproval = LoginItem.needsApproval

    private let webReaders: [Provider: WebUsageReader] = [
        .claude: .claude(), .codex: .codex(), .gemini: .gemini(),
    ]

    /// 웹에서 받아온 실시간 값. 있으면 로컬 폴백보다 우선한다.
    private var live: [Provider: ProviderUsage] = [:]
    /// 웹 조회가 실패한 이유. 10초마다 도는 로컬 갱신이 이걸 지우면 로그인 안내가 사라진다.
    private var webNote: [Provider: String] = [:]
    private var started = false
    private let notifier = LimitNotifier()

    /// 한도 임박 알림. 기본으로 켜둔다 — 이 앱을 띄우는 이유가 그거다.
    @Published private(set) var notifyNearLimit = UserDefaults.standard
        .object(forKey: "notifyNearLimit") as? Bool ?? true
    /// 웹 조회는 웹뷰를 만들고 끝나면 버린다. 두 작업이 겹치면 한쪽의 teardown이
    /// 다른 쪽이 쓰는 웹뷰를 없애버린다. "새로 고침" 버튼과 예약 갱신이 겹칠 수 있다.
    /// 화면에도 보여준다 — 몇 초 걸리는데 표시가 없으면 눌러도 반응이 없는 걸로 보인다.
    @Published private(set) var isRefreshingWeb = false

    /// 로컬 파일 읽기는 싸다.
    private let localInterval: Duration = .seconds(10)

    /// 웹뷰 조회 주기. 벤더 페이지를 실제로 여는 작업이라 사용자가 고를 수 있게 했다.
    @Published private(set) var refreshInterval: RefreshInterval = {
        let stored = UserDefaults.standard.integer(forKey: "refreshIntervalMinutes")
        return RefreshInterval(rawValue: stored) ?? .fiveMinutes
    }()

    /// 메뉴바에 하나만 띄울지 전부 띄울지.
    @Published private(set) var menuBarStyle: MenuBarStyle = {
        let stored = UserDefaults.standard.string(forKey: "menuBarStyle") ?? ""
        return MenuBarStyle(rawValue: stored) ?? .urgent
    }()

    init() { start() }

    private func start() {
        guard !started else { return }
        started = true
        Self.debug("UsageModel.init")
        LoginItem.registerOnFirstLaunch()
        refreshLoginItemState()
        Task {
            guard notifyNearLimit else { return }
            // 앱이 완전히 기동한 뒤에 물어본다. init 시점엔 아직 알림 시스템에 등록 전이라
            // "not allowed" 로 거절당한다.
            try? await Task.sleep(for: .seconds(3))
            await notifier.requestAuthorizationIfNeeded()
            notificationsUnavailableReason = notifier.unavailableReason
            // 진단 모드에서는 알림이 실제로 도착하는지까지 확인할 수 있어야 한다.
            // 권한만 받고 전달이 안 되는 경우가 따로 있다.
            if Self.debugEnabled { notifier.sendEnabledConfirmation() }
        }
        Task { await loop({ self.localInterval }) { await self.refreshLocal() } }
        // 주기는 설정에서 바뀔 수 있으므로 매 회차에 다시 읽는다.
        Task { await loop({ .seconds(self.refreshInterval.minutes * 60) }) { await self.refreshWeb() } }
    }

    private func loop(_ every: @escaping () -> Duration,
                      _ body: @escaping () async -> Void) async {
        while !Task.isCancelled {
            await body()
            try? await Task.sleep(for: every())
        }
    }

    // MARK: - 갱신

    /// 로컬 파일에서 읽는 폴백 값. 웹 로그인 전에도 뭔가는 보여준다.
    ///
    /// 이미 실시간 값이 있는 제공자는 건너뛴다. CodexReader 는 ~/.codex/sessions 디렉터리
    /// 전체를 훑으므로, 쓰지도 않을 값을 10초마다 읽을 이유가 없다.
    private func localFallbacks(now: Date, skippingLive: Bool = true) async -> [ProviderUsage] {
        let needed = Provider.allCases.filter { p in
            p != .gemini && (!skippingLive || live[p] == nil)   // Gemini 는 로컬 출처가 없다
        }
        guard !needed.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            needed.compactMap { provider in
                switch provider {
                case .claude: return ClaudeReader.read(now: now)
                case .codex: return CodexReader.read(now: now)
                case .gemini: return nil
                }
            }
        }.value
    }

    func refreshLocal() async {
        let now = Date()
        for fallback in await localFallbacks(now: now) {
            // 웹에서 실시간 값을 받아둔 게 있으면 건드리지 않는다.
            guard live[fallback.provider] == nil else { continue }
            // 웹 실패 사유(로그인 필요 등)를 같이 실어야 한다.
            // 안 그러면 안내가 10초 만에 지워져서 로그인 버튼을 찾을 수 없다.
            replace(ProviderUsage(provider: fallback.provider, windows: fallback.windows,
                                  updatedAt: fallback.updatedAt, plan: fallback.plan,
                                  note: webNote[fallback.provider] ?? fallback.note))
        }
        if notifyNearLimit { notifier.check(usages) }
        Self.debug("메뉴바 = \"\(menuBarText)\" / 실시간=\(live.keys.map(\.rawValue).sorted())")
    }

    func refreshWeb() async {
        guard !isRefreshingWeb else { return }
        isRefreshingWeb = true
        defer { isRefreshingWeb = false }

        let now = Date()
        // 여기서는 실시간 여부와 무관하게 읽는다. 웹이 리셋 시각을 빠뜨렸을 때 채워야 한다.
        let fallbacks = Dictionary(uniqueKeysWithValues:
            await localFallbacks(now: now, skippingLive: false).map { ($0.provider, $0) })

        for provider in Provider.allCases {
            guard let reader = webReaders[provider] else { continue }
            refreshingProvider = provider
            let started = Date()
            let result = await reader.fetch()
            let detail = result.windows.isEmpty
                ? (result.note ?? "실패")
                : "[\(result.plan ?? "-")] "
                  + result.windows.map { "\($0.label) \($0.summary())" }.joined(separator: " | ")
            Self.debug("  \(provider.rawValue): \(String(format: "%.0f", Date().timeIntervalSince(started)))초 · \(detail)")

            if !result.windows.isEmpty {
                // 웹이 리셋 시각을 못 준 창은 로컬의 정확한 값으로 채운다.
                // 퍼센트는 숫자라 언어를 안 타지만 날짜 문구는 지역 형식을 타기 때문이다.
                let merged = ProviderUsage(
                    provider: provider,
                    windows: fillingMissingResets(result.windows,
                                                  from: fallbacks[provider]?.windows ?? []),
                    updatedAt: result.updatedAt,
                    plan: result.plan ?? fallbacks[provider]?.plan)
                live[provider] = merged
                webNote[provider] = nil
                replace(merged)
                continue
            }

            // 웹을 못 읽었으면 로컬로 돌아가되, 왜 실시간이 아닌지는 알린다.
            live[provider] = nil
            guard let fallback = fallbacks[provider], !fallback.windows.isEmpty else {
                webNote[provider] = result.note
                replace(result)
                continue
            }
            webNote[provider] = "\(result.note ?? L10n.fetchFailed) · \(L10n.showingLocal)"
            replace(ProviderUsage(provider: provider, windows: fallback.windows,
                                  updatedAt: fallback.updatedAt, plan: fallback.plan,
                                  note: webNote[provider]))
        }
        refreshingProvider = nil
        Self.debug("웹 갱신 완료: 실시간=\(live.keys.map(\.rawValue).sorted())")
    }

    func refreshAll() {
        Task { await refreshLocal() }
        Task { await refreshWeb() }
    }

    /// 지금 조회 중인 제공자. 어디까지 갔는지 보여준다.
    @Published private(set) var refreshingProvider: Provider?

    // MARK: - 로그인 항목

    func login(to provider: Provider) { webReaders[provider]?.showLogin() }

    /// 기본 브라우저에서 벤더 사용량 페이지를 연다.
    /// 앱 웹뷰가 막히거나 수치가 의심스러울 때 직접 대조할 수 있어야 한다.
    func openUsagePage(for provider: Provider) {
        guard let url = webReaders[provider]?.publicURL else { return }
        Self.debug("페이지 열기: \(provider.rawValue) → \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    func setLoginItem(_ on: Bool) {
        do { try LoginItem.setEnabled(on) }
        catch { Self.debug("로그인 항목 변경 실패: \(error.localizedDescription)") }
        refreshLoginItemState()
    }

    func openLoginItemsSettings() { LoginItem.openLoginItemsSettings() }

    func setRefreshInterval(_ interval: RefreshInterval) {
        refreshInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: "refreshIntervalMinutes")
        // 더 짧게 바꿨으면 다음 회차를 기다리지 않고 바로 반영해준다.
        Task { await refreshWeb() }
    }

    func setMenuBarStyle(_ style: MenuBarStyle) {
        menuBarStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: "menuBarStyle")
    }

    func setNotifyNearLimit(_ on: Bool) {
        notifyNearLimit = on
        UserDefaults.standard.set(on, forKey: "notifyNearLimit")
        notifier.reset()   // 껐다 켰을 때 직전 상태 때문에 조용해지지 않게
        if on {
            Task {
                await notifier.requestAuthorizationIfNeeded()
                notificationsUnavailableReason = notifier.unavailableReason
                notifier.sendEnabledConfirmation()
            }
        }
    }

    /// 알림을 쓸 수 없는 빌드면 그 이유. 체크박스를 비활성으로 만들고 사유를 보여준다.
    @Published private(set) var notificationsUnavailableReason: String?

    /// 시스템 설정에서 사용자가 직접 끌 수 있으므로 표시 전에 실제 상태를 다시 읽는다.
    func refreshLoginItemState() {
        loginItemEnabled = LoginItem.isEnabled
        loginItemNeedsApproval = LoginItem.needsApproval
    }

    // MARK: - 표시

    /// 메뉴바에 올릴 제공자. 아이콘을 붙이려면 어느 쪽인지 알아야 한다.
    var menuBarProvider: Provider? { mostUrgent(among: usages)?.0.provider }

    var menuBarText: String { UsageCore.menuBarText(for: usages) }

    /// `.all` 모드에서 제공자별로 아이콘과 함께 늘어놓을 항목.
    var menuBarEntries: [(provider: Provider, text: String)] {
        UsageCore.menuBarEntries(for: usages)
    }

    /// 메뉴바에 경고를 띄울지. 알림과 달리 권한이 필요 없어서 어떤 빌드에서도 동작한다.
    var menuBarSeverity: UsageWindow.Severity {
        mostUrgent(among: usages)?.1.severity ?? .normal
    }

    /// 웹 로그인이 아직 안 된 제공자들. 패널 하단에 항상 보여줘서 찾을 수 있게 한다.
    var providersNeedingLogin: [Provider] {
        Provider.allCases.filter { live[$0] == nil }
    }

    private func replace(_ u: ProviderUsage) {
        if let i = usages.firstIndex(where: { $0.provider == u.provider }) {
            usages[i] = u
        } else {
            usages.append(u)
            let order = Provider.allCases
            usages.sort { order.firstIndex(of: $0.provider)! < order.firstIndex(of: $1.provider)! }
        }
    }

    // MARK: - 진단

    /// 메뉴바 앱은 stdout이 없고 NSLog도 `log show`에 안 잡힌다.
    /// 그래서 시작이 아예 안 걸리는 종류의 버그가 눈에 안 보인다. 파일로 남길 수단을 남겨둔다.
    ///
    ///   TOKENUSAGE_DEBUG=1 /Applications/TokenUsage.app/Contents/MacOS/TokenUsage
    private static let debugEnabled = ProcessInfo.processInfo.environment["TOKENUSAGE_DEBUG"] == "1"

    static func debug(_ msg: String) {
        guard debugEnabled else { return }
        let line = "\(Date()) \(msg)\n"
        let url = URL(fileURLWithPath: "/tmp/tokenusage-debug.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
