import Foundation
import ServiceManagement

/// 로그인 항목 등록. macOS 13+의 SMAppService를 쓴다.
/// LaunchAgent plist를 직접 만들던 옛 방식은 필요 없다 — 시스템 설정의 "로그인 항목"에
/// 그대로 나타나고, 사용자가 거기서 끄면 그게 곧 진실이 된다.
enum LoginItem {
    /// 사용자가 한 번이라도 직접 정한 뒤에는 앱이 다시 손대지 않는다.
    private static let autoRegisteredKey = "didAutoRegisterLoginItem"

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var statusText: String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        case .requiresApproval: return "requiresApproval"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    static var isEnabled: Bool { status == .enabled }

    /// 승인이 필요한 상태면 시스템 설정에서 켜줘야 한다. UI에 그대로 알린다.
    static var needsApproval: Bool { status == .requiresApproval }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        // 사용자가 직접 정했으므로 앞으로 자동 등록하지 않는다.
        UserDefaults.standard.set(true, forKey: autoRegisteredKey)
    }

    /// 첫 실행에서 한 번만 자동 등록한다.
    ///
    /// 사용자가 나중에 끄면 다시 켜지 않는다. 껐는데 다음 실행에 되살아나는 앱은
    /// 고쳐야 할 버그지 기능이 아니다.
    static func registerOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: autoRegisteredKey) else { return }
        UserDefaults.standard.set(true, forKey: autoRegisteredKey)
        // 이미 켜져 있을 때만 건너뛴다. notFound/notRegistered 모두 등록을 시도한다.
        guard status != .enabled else { return }
        register()
    }

    /// 등록을 시도하고 결과를 남긴다. 실패 이유를 알아야 사용자에게 뭘 하라고 말할 수 있다.
    @discardableResult
    static func register() -> String {
        let before = statusText
        do {
            try SMAppService.mainApp.register()
            let result = "등록 시도: \(before) -> \(statusText)"
            lastError = status == .enabled || status == .requiresApproval ? nil : result
            return result
        } catch {
            let result = "등록 실패(\(before)): \(error.localizedDescription)"
            lastError = error.localizedDescription
            return result
        }
    }

    /// 실패했을 때 UI에 보여줄 사유.
    private(set) static var lastError: String?

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
