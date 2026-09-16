import SwiftUI
import UsageCore

@main
struct TokenUsageApp: App {
    @StateObject private var model = UsageModel()

    init() {
        // 문서 이미지를 만들고 끝내는 경로. 평소 실행에는 영향이 없다.
        MainActor.assumeIsolated { Snapshot.runIfRequested() }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // 여기에 .task를 붙이면 호출되지 않는다. MenuBarExtra의 label은 일반 뷰
            // 생명주기를 타지 않는다. 그래서 갱신 시작은 UsageModel.init()에서 건다.
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
