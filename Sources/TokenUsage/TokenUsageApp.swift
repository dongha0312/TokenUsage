import SwiftUI

@main
struct TokenUsageApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // 여기에 .task를 붙이면 호출되지 않는다. MenuBarExtra의 label은 일반 뷰
            // 생명주기를 타지 않는다. 그래서 갱신 시작은 UsageModel.init()에서 건다.
            if let provider = model.menuBarProvider {
                ProviderIcon(provider: provider, size: 16)
            }
            // 알림은 서명된 빌드에서만 되므로, 권한이 필요 없는 메뉴바가 1차 경고 수단이다.
            if model.menuBarSeverity != .normal {
                Image(systemName: model.menuBarSeverity == .critical
                      ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
            }
            Text(model.menuBarText)
        }
        .menuBarExtraStyle(.window)
    }
}
