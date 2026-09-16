import AppKit
import SwiftUI
import UsageCore

/// 각 제공자의 아이콘은 이 맥에 설치된 앱에서 그대로 가져온다.
///
/// 로고를 직접 그리거나 이미지 파일을 번들에 넣지 않는 이유:
/// 정품 아이콘이 이미 디스크에 있고, 앱이 업데이트되면 아이콘도 따라 갱신된다.
/// 에셋도, 상표 이미지 사본도 남기지 않는다.
extension Provider {
    /// 먼저 찾히는 것을 쓴다. Codex는 ChatGPT 앱에 들어 있다.
    var appBundleIdentifiers: [String] {
        switch self {
        case .claude: return ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .codex:  return ["com.openai.codex", "com.openai.chat"]
        case .gemini: return ["com.google.GeminiMacOS"]
        }
    }

    /// 앱이 없을 때만 쓰는 대체 표기. 한 글자로는 Claude와 Codex가 겹친다.
    var fallbackText: String {
        switch self {
        case .claude: return "Cl"
        case .codex:  return "Cx"
        case .gemini: return "Gm"
        }
    }

    /// NSWorkspace 조회는 싸지 않으니 한 번만 한다.
    private static var iconCache: [Provider: NSImage] = [:]

    func icon(size: CGFloat) -> NSImage? {
        if let cached = Provider.iconCache[self] { return cached.resized(to: size) }
        let ws = NSWorkspace.shared
        for id in appBundleIdentifiers {
            guard let url = ws.urlForApplication(withBundleIdentifier: id) else { continue }
            let image = ws.icon(forFile: url.path)
            Provider.iconCache[self] = image
            return image.resized(to: size)
        }
        return nil
    }
}

private extension NSImage {
    func resized(to side: CGFloat) -> NSImage {
        let target = NSSize(width: side, height: side)
        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: target),
             from: NSRect(origin: .zero, size: size),
             operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }
}

/// 아이콘이 있으면 아이콘, 없으면 짧은 글자.
struct ProviderIcon: View {
    let provider: Provider
    var size: CGFloat = 14

    var body: some View {
        if let icon = provider.icon(size: size) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Text(provider.fallbackText)
                .font(.system(size: size * 0.7, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}
