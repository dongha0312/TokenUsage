import Foundation
import UsageCore
import UserNotifications

/// 한도에 가까워지면 알린다. 80% 넘으면 한 번, 95% 넘으면 다시 한 번.
///
/// 같은 단계에서 반복해 울리지 않는다. 창이 초기화돼 정상으로 돌아오면 다시 알릴 수 있게 푼다.
/// 그러지 않으면 5분마다 같은 알림이 와서 결국 알림을 꺼버리게 된다.
@MainActor
final class LimitNotifier {
    private var lastNotified: [String: UsageWindow.Severity] = [:]
    private var authorized = false
    private var asked = false

    /// 알림을 아예 쓸 수 없는 빌드인지. ad-hoc 서명으로는 macOS가 거부한다.
    /// 끌 수 없는 체크박스를 남겨두느니 이유를 밝히고 비활성으로 보여주는 게 낫다.
    private(set) var unavailableReason: String?

    func requestAuthorizationIfNeeded() async {
        guard !authorized, !asked else { return }
        asked = true
        let center = UNUserNotificationCenter.current()
        do {
            authorized = try await center.requestAuthorization(options: [.alert, .sound])
            UsageModel.debug("알림 권한: \(authorized ? "허용" : "사용자가 거부")")
        } catch {
            authorized = false
            // UNErrorDomain 1 = Notifications are not allowed (서명되지 않은 빌드)
            unavailableReason = L10n.notificationsUnavailable
            UsageModel.debug("알림 권한 오류: \(error)")
        }
    }

    func check(_ usages: [ProviderUsage]) {
        for usage in usages {
            for window in usage.windows {
                let key = "\(usage.provider.rawValue):\(window.kind.id)"
                let previous = lastNotified[key] ?? .normal

                guard window.severity != .normal else {
                    lastNotified[key] = .normal   // 초기화됐으니 다음에 다시 알릴 수 있다
                    continue
                }
                guard window.severity != previous else { continue }   // 이 단계는 이미 알렸다

                lastNotified[key] = window.severity
                post(provider: usage.provider, window: window)
            }
        }
    }

    /// 켤 때 확인 알림을 한 번 보낸다.
    /// 권한이 실제로 붙었는지, 알림이 정말 오는지를 사용자가 바로 알 수 있어야 한다.
    func sendEnabledConfirmation() {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.notificationsOnTitle
        content.body = L10n.notificationsOnBody
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        UsageModel.debug("확인 알림 발송")
    }

    /// 사용자가 알림을 껐다 켜면 직전 상태 때문에 조용해지지 않도록 기록을 비운다.
    func reset() {
        lastNotified.removeAll()
        asked = false
    }

    private func post(provider: Provider, window: UsageWindow) {
        guard let used = window.usedPercent else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.nearLimitTitle(provider.rawValue)
        content.body = L10n.nearLimitBody(window.label,
                                          percent: Int(used.rounded()),
                                          reset: window.timeToReset())
        content.sound = window.severity == .critical ? .default : nil

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        UsageModel.debug("알림: \(content.title) · \(content.body)")
    }
}
