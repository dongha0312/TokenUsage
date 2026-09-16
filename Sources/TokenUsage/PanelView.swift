import SwiftUI
import UsageCore

struct PanelView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.usages.enumerated()), id: \.element.provider) { index, usage in
                if index > 0 { Divider().padding(.vertical, 12) }
                ProviderSection(
                    usage: usage,
                    onLogin: { model.login(to: usage.provider) },
                    onOpenPage: { model.openUsagePage(for: usage.provider) })
            }

            Divider().padding(.vertical, 12)
            footer
        }
        .padding(16)
        .frame(width: 330)
        // 시스템 설정에서 사용자가 직접 껐을 수 있으므로 열 때마다 실제 상태를 다시 읽는다.
        .onAppear { model.refreshLoginItemState() }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L10n.launchAtLogin, isOn: Binding(
                get: { model.loginItemEnabled },
                set: { model.setLoginItem($0) }))

            Toggle(L10n.notifyNearLimit, isOn: Binding(
                get: { model.notifyNearLimit },
                set: { model.setNotifyNearLimit($0) }))
                .disabled(model.notificationsUnavailableReason != nil)

            if let reason = model.notificationsUnavailableReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 18)
            }

            if model.loginItemNeedsApproval {
                Button(L10n.approveInSettings) { model.openLoginItemsSettings() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }

            // 실시간 값을 받으려면 웹 로그인이 필요하다. 안내 문구에만 숨겨두면 못 찾는다.
            let needLogin = model.providersNeedingLogin
            if !needLogin.isEmpty {
                HStack(spacing: 4) {
                    Text(L10n.liveSignIn).foregroundStyle(.secondary)
                    ForEach(needLogin, id: \.self) { provider in
                        Button(provider.rawValue) { model.login(to: provider) }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption2)
                .padding(.top, 2)
            }

            HStack(spacing: 6) {
                // 조회가 몇 초 걸린다. 진행 표시가 없으면 눌러도 반응이 없는 걸로 보인다.
                Button(L10n.refresh) { model.refreshAll() }
                    .buttonStyle(.link)
                    .disabled(model.isRefreshingWeb)

                if model.isRefreshingWeb {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                    Text(model.refreshingProvider.map { L10n.checking($0.rawValue) } ?? L10n.refreshing)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Button(L10n.quit) { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link)
            }
            .padding(.top, 6)
        }
        .toggleStyle(.checkbox)
        .font(.caption)
    }
}

private struct ProviderSection: View {
    let usage: ProviderUsage
    let onLogin: () -> Void
    let onOpenPage: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ProviderIcon(provider: usage.provider, size: 15)
                Text(usage.provider.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let plan = usage.plan {
                    Text(plan)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                // 수치가 의심스러우면 벤더 페이지에서 직접 대조할 수 있어야 한다.
                Button(action: onOpenPage) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(hovering ? .primary : .tertiary)
                .help(L10n.openUsagePage)
            }
            .onHover { hovering = $0 }

            if let note = usage.note {
                HStack(spacing: 6) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if note.contains("로그인") || note.lowercased().contains("sign in") {
                        Button(L10n.signIn, action: onLogin)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }

            ForEach(usage.windows, id: \.kind.id) { window in
                WindowRow(window: window)
            }

            // 이 수치가 언제 기준인지 항상 밝힌다.
            if let ago = updatedAgo(usage.updatedAt) {
                HStack {
                    Spacer()
                    Text(ago)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                }
            }
        }
    }
}

private struct WindowRow: View {
    let window: UsageWindow

    /// 평소에는 파랑. 많이 썼을 때만 경고색으로 넘어간다.
    private var tint: Color {
        switch window.severity {
        case .critical: return .red
        case .warning: return .orange
        case .normal: return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Text(window.summary())
                    .font(.system(size: 12))
                    .foregroundStyle(window.severity == .normal ? .secondary : tint)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if let used = window.usedPercent {
                        Capsule().fill(tint)
                            // 0%일 때도 존재를 보이게 최소 폭을 준다.
                            .frame(width: max(4, geo.size.width * used / 100))
                    }
                }
            }
            .frame(height: 7)
        }
    }
}
