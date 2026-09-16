import SwiftUI
import UsageCore

/// 메뉴바에 들어가는 내용. 앱과 설정 미리보기, 문서용 스냅샷이 같은 코드를 쓴다.
/// 미리보기를 따로 그리면 실제와 어긋나고, 어긋난 걸 눈치채기도 어렵다.
struct MenuBarLabel: View {
    @ObservedObject var model: UsageModel
    /// nil 이면 사용자의 설정을 따른다. 설정 화면의 미리보기만 특정 방식을 강제한다.
    /// 미리보기 때문에 모델을 새로 만들면 안 된다 — 설정 저장까지 따라 일어난다.
    var style: MenuBarStyle?
    var iconSize: CGFloat = 16

    var body: some View {
        switch style ?? model.menuBarStyle {
        case .urgent:
            if let provider = model.menuBarProvider {
                ProviderIcon(provider: provider, size: iconSize)
            }
            // 알림은 서명·번들 조건을 타므로, 권한이 필요 없는 메뉴바가 1차 경고 수단이다.
            if model.menuBarSeverity != .normal {
                Image(systemName: model.menuBarSeverity == .critical
                      ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
            }
            Text(model.menuBarText)
        case .all:
            ForEach(model.menuBarEntries, id: \.provider) { entry in
                ProviderIcon(provider: entry.provider, size: iconSize - 2)
                Text(entry.text)
            }
        }
    }
}
