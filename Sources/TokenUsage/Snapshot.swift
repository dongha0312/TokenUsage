import AppKit
import SwiftUI
import UsageCore

/// 문서용 이미지 생성.
///
///     TokenUsage --snapshot docs
///
/// 목업을 따로 그리지 않는다. 앱에 들어가는 뷰(PanelView·MenuBarLabel)를 그대로 렌더하므로
/// UI 를 고치면 이미지도 따라 바뀐다. 손으로 찍은 스크린샷은 금방 실제와 어긋난다.
@MainActor
enum Snapshot {
    /// `--snapshot <디렉터리>` 로 실행됐으면 이미지를 만들고 끝낸다.
    ///
    /// ImageRenderer 는 쓰지 않는다. AppKit 이 뒤를 받치는 컨트롤(Toggle·Picker·Button·
    /// ProgressView)을 제대로 못 그려서, 텍스트가 통째로 빠지고 체크박스가 깨져 나온다.
    /// 대신 실제 창에 얹어 AppKit 렌더 경로로 캡처한다 — 화면에 뜨는 것과 같은 그림이다.
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot") else { return }
        let dir = i + 1 < args.count ? args[i + 1] : "docs"

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            captureAll(into: dir)
            exit(0)
        }
        app.run()   // SwiftUI 앱 대신 여기서 끝난다
    }

    private static func captureAll(into dir: String) {
        for (appearance, suffix) in [(NSAppearance(named: .darkAqua), "dark"),
                                     (NSAppearance(named: .aqua), "light")] {
            capture(PanelView(model: sampleModel()), appearance: appearance,
                    to: "\(dir)/panel-\(suffix).png")
            for style in MenuBarStyle.allCases {
                capture(menuBarStrip(style: style), appearance: appearance,
                        to: "\(dir)/menubar-\(style.rawValue)-\(suffix).png")
            }
        }
    }

    /// 창에 얹고, 레이아웃이 끝날 때까지 런루프를 돌린 뒤, 그려진 그대로 떠낸다.
    ///
    /// 배경을 반드시 깔아야 한다. 실제로는 메뉴바 패널이 재질 배경을 제공하지만 캡처에는
    /// 그게 없어서, 다크 모드의 흰 글자가 투명 위에 찍혀 그대로 사라진다.
    private static func capture(_ view: some View, appearance: NSAppearance?, to path: String) {
        let host = NSHostingView(rootView: view.background(
            Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        // 화면 밖에 둔다. 스냅샷을 뜨자고 사용자 화면에 창을 띄울 이유는 없다.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)

        // SwiftUI 가 한 번에 자리를 잡지 않는다. 몇 번 돌려준다.
        for _ in 0..<12 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("실패: \(path)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("실패: \(path)")
            return
        }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
        print("생성: \(path)  \(Int(size.width))x\(Int(size.height))")
    }

    /// 문서에 쓸 상황. 실제로 있을 법한 값으로 두되 계정 수치는 쓰지 않는다.
    /// Codex 세션을 경고 구간에 둬서 색과 메뉴바 경고 표시가 어떻게 보이는지도 함께 담는다.
    private static func sampleModel() -> UsageModel {
        let now = Date()
        return UsageModel(sample: [
            ProviderUsage(provider: .claude, windows: [
                UsageWindow(kind: .session(hours: 5), usedPercent: 34,
                            resetsAt: now.addingTimeInterval(3 * 3600 + 600)),
                UsageWindow(kind: .weeklyAllModels, usedPercent: 12,
                            resetsAt: now.addingTimeInterval(3 * 86400)),
                UsageWindow(kind: .weeklyScoped("Opus"), usedPercent: 3,
                            resetsAt: now.addingTimeInterval(3 * 86400)),
            ], updatedAt: now, plan: "MAX"),
            ProviderUsage(provider: .codex, windows: [
                UsageWindow(kind: .session(hours: 5), usedPercent: 86,
                            resetsAt: now.addingTimeInterval(41 * 60)),
                UsageWindow(kind: .weekly, usedPercent: 45,
                            resetsAt: now.addingTimeInterval(2 * 86400)),
            ], updatedAt: now.addingTimeInterval(-14 * 60), plan: "PLUS"),
            ProviderUsage(provider: .gemini, windows: [
                UsageWindow(kind: .session(hours: nil), usedPercent: 8,
                            resetsAt: now.addingTimeInterval(52 * 60)),
                UsageWindow(kind: .weekly, usedPercent: 21,
                            resetsAt: now.addingTimeInterval(5 * 86400)),
            ], updatedAt: now, plan: "PRO"),
        ])
    }

    /// 메뉴바 한 칸처럼 보이게 감싼다.
    private static func menuBarStrip(style: MenuBarStyle) -> some View {
        HStack(spacing: 4) {
            MenuBarLabel(model: sampleModel(), style: style, iconSize: 16)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        .padding(10)
    }

}
