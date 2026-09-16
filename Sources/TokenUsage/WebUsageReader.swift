import AppKit
import UsageCore
import WebKit

/// 숨은 WKWebView로 벤더의 사용량 페이지를 띄우고 텍스트만 읽어온다.
///
/// 자격증명을 어디서도 꺼내지 않는다. 웹뷰가 자기 쿠키를 갖고, 사용자는 앱 안에서 한 번 로그인한다.
/// Keychain에서 토큰을 뽑아 비공개 API를 부르는 방식이 더 빠르지만, 항상 떠 있는 앱이
/// 자격증명을 계속 만지게 되는 걸 피했다.
@MainActor
final class WebUsageReader {
    struct Config {
        let provider: Provider
        let url: URL
        let windowTitle: String
        let isLoaded: (String) -> Bool
        let parse: (String, Date) -> (windows: [UsageWindow], plan: String?)
        /// 로그인 안내에 쓸 호스트 이름
        let host: String
        /// 브라우저에서 직접 열 주소. 앱 웹뷰에서 문제가 생겨도 여기로 갈 수 있다.
        let publicURL: URL
    }

    var publicURL: URL { config.publicURL }
    var loginNote: String { L10n.loginNeeded(config.host) }

    /// 구글은 임베디드 웹뷰에서의 로그인을 막는 경우가 있다. Safari로 보이게 맞춘다.
    private static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private let config: Config

    /// 웹뷰는 조회할 때만 만들고 끝나면 버린다.
    ///
    /// WKWebView 하나가 WebContent·Networking·GPU 보조 프로세스를 끌고 온다. 실측으로 웹뷰 둘을
    /// 상주시키니 ~57MB가 놀고 있었다. 실제로 쓰는 건 5분에 30초뿐이라 그동안만 들고 있는다.
    /// 쿠키는 `.default()` 데이터 저장소에 남으므로 버려도 로그인은 유지된다.
    private var webView: WKWebView?
    private var window: NSWindow?

    init(_ config: Config) { self.config = config }

    private func makeWebView() -> WKWebView {
        if let webView { return webView }
        let wkConfig = WKWebViewConfiguration()
        wkConfig.websiteDataStore = .default()   // 쿠키를 디스크에 유지해 로그인을 한 번만 하게 한다
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 850),
                             configuration: wkConfig)
        view.customUserAgent = Self.safariUA

        // ponytail: 창에 붙여야 WKWebView가 정상 동작한다. 평소엔 띄우지 않고,
        // 로그인이 필요할 때만 showLogin()으로 보여준다.
        let win = NSWindow(contentRect: view.frame,
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = config.windowTitle
        win.isReleasedWhenClosed = false
        win.contentView = view

        webView = view
        window = win
        return view
    }

    private func teardown() {
        // 로그인 창을 열어둔 동안에는 없애지 않는다.
        guard window?.isVisible != true else { return }
        webView?.stopLoading()
        window?.contentView = nil
        window = nil
        webView = nil
    }

    func showLogin() {
        let view = makeWebView()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        view.load(URLRequest(url: config.url))
    }

    private func pageText(_ view: WKWebView) async -> String? {
        await withCheckedContinuation { cont in
            view.evaluateJavaScript("document.body.innerText") { result, _ in
                cont.resume(returning: result as? String)
            }
        }
    }

    /// 로그인 페이지로 튕겼는지. 여기 걸리면 기다릴 이유가 없다.
    private static func isLoginURL(_ url: String) -> Bool {
        let markers = ["accounts.google.com", "ServiceLogin",
                       "auth.openai.com", "auth0.openai.com",
                       "/login", "/auth/login", "/sign-in", "/signin"]
        return markers.contains { url.contains($0) }
    }

    /// chatgpt.com·gemini.google.com 은 리다이렉트 없이 같은 URL에서 로그인·랜딩 화면을 그린다.
    /// URL로는 못 잡으므로 내용으로 본다. 사용량 문구가 없다는 게 이미 확인된 뒤에만 쓴다.
    private static func looksLikeLogin(_ text: String) -> Bool {
        let markers = ["로그인", "Log in", "Sign in", "Sign up", "회원가입",
                       "계속하려면", "Continue with Google", "Stay logged out"]
        return markers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// 로딩 중 잠깐 빈 화면이나 랜딩이 스칠 수 있어 초반 몇 초는 판정을 미룬다.
    private static let loginGrace: TimeInterval = 6

    func fetch(now: Date = Date()) async -> ProviderUsage {
        let view = makeWebView()
        view.load(URLRequest(url: config.url))
        defer { teardown() }

        // SPA라 로드 완료와 내용 렌더가 어긋난다. 문구가 뜰 때까지 짧게 재확인한다.
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(30)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(1))

            // 로그인 페이지로 튕겼으면 타임아웃까지 기다리지 않는다.
            // 미로그인 상태에서 제공자 셋이 각각 30초를 태우면 5분마다 92초를 낭비하게 된다.
            if let url = view.url?.absoluteString, Self.isLoginURL(url) {
                return .unavailable(config.provider, loginNote)
            }

            guard let text = await pageText(view) else { continue }
            guard config.isLoaded(text) else {
                if Date().timeIntervalSince(startedAt) > Self.loginGrace,
                   Self.looksLikeLogin(text) {
                    return .unavailable(config.provider, loginNote)
                }
                continue
            }

            // 제목이 떴다고 다 그려진 게 아니다. SPA는 제목을 먼저 그리고 숫자를 나중에 채운다.
            // 숫자가 실제로 파싱될 때까지 기다린다. 여기서 성급하게 돌아가면
            // "페이지 구조가 바뀐 듯"이라고 잘못 보고하게 된다.
            let parsed = config.parse(text, now)
            guard !parsed.windows.isEmpty else { continue }
            return ProviderUsage(provider: config.provider, windows: parsed.windows,
                                 updatedAt: now, plan: parsed.plan)
        }

        let url = view.url?.absoluteString ?? ""
        if Self.isLoginURL(url) { return .unavailable(config.provider, loginNote) }

        // 시간이 다 됐다. 원인을 보려면 실제로 뭐가 그려졌는지가 필요하다.
        let finalText = await pageText(view) ?? ""
        let snippet = finalText.prefix(300).replacingOccurrences(of: "\n", with: " / ")
        UsageModel.debug("    \(config.provider.rawValue) 실패: url=\(url)"
                         + " / 본문=\(snippet.isEmpty ? "(비어 있음)" : snippet)")
        if config.isLoaded(finalText) {
            // 화면은 떴는데 끝까지 숫자를 못 뽑았다 — 진짜로 구조가 바뀐 경우.
            return .unavailable(config.provider, L10n.pageChanged)
        }
        // 어디에 떨어졌는지 남겨야 원인을 볼 수 있다.
        return .unavailable(config.provider,
                            L10n.pageUnreadable(URL(string: url)?.host ?? "?"))
    }
}

extension WebUsageReader {
    static func claude() -> WebUsageReader {
        WebUsageReader(.init(
            provider: .claude,
            url: URL(string: "https://claude.ai/settings/usage")!,
            windowTitle: "Claude",
            isLoaded: ClaudeWebParse.isLoaded,
            parse: { text, now in
                (ClaudeWebParse.windows(from: text, now: now), ClaudeWebParse.plan(from: text))
            },
            host: "claude.ai",
            publicURL: URL(string: "https://claude.ai/settings/usage")!))
    }

    static func codex() -> WebUsageReader {
        WebUsageReader(.init(
            provider: .codex,
            url: URL(string: "https://chatgpt.com/codex/cloud/settings/analytics#usage")!,
            windowTitle: "ChatGPT",
            isLoaded: CodexWebParse.isLoaded,
            parse: { text, now in
                (CodexWebParse.windows(from: text, now: now), CodexWebParse.plan(from: text))
            },
            host: "chatgpt.com",
            publicURL: URL(string: "https://chatgpt.com/codex/cloud/settings/analytics#usage")!))
    }

    static func gemini() -> WebUsageReader {
        WebUsageReader(.init(
            provider: .gemini,
            // hl=en 고정: 페이지 언어가 바뀌면 파서가 깨지므로 영어로 못박는다.
            url: URL(string: "https://gemini.google.com/usage?hl=en")!,
            windowTitle: "Gemini",
            isLoaded: GeminiParse.isLoaded,
            parse: { text, now in
                (GeminiParse.windows(from: text, now: now), GeminiParse.plan(from: text))
            },
            host: "gemini.google.com",
            publicURL: URL(string: "https://gemini.google.com/usage")!))
    }
}
