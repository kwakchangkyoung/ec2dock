import AppKit
import EC2DockCore
import SwiftTerm
import SwiftUI

/// 메인 창의 상세 영역. 열린 터미널이 있으면 위에 탭 막대를 두고
/// "서버 정보"와 각 터미널 세션 사이를 오간다.
struct DetailArea: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    let selectedServerID: String?

    var body: some View {
        VStack(spacing: 0) {
            if !terminals.sessions.isEmpty {
                SessionTabBar()
                Divider()
            }
            if let id = terminals.activeSessionID, let controller = terminals.controller(id: id) {
                TerminalSessionView(controller: controller)
                    .id(controller.id)
            } else if let id = selectedServerID, let item = state.item(id: id) {
                ServerDetailView(item: item)
                    .id(item.id)
            } else {
                ContentUnavailableView("서버를 선택하세요", systemImage: "server.rack")
            }
        }
    }
}

// MARK: - 탭 막대

private struct SessionTabBar: View {
    @Environment(TerminalSessionStore.self) private var terminals
    @ViewState private var pendingClose: TerminalSessionController?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                TabButton(isSelected: terminals.activeSessionID == nil) {
                    terminals.activeSessionID = nil
                } label: {
                    Label("서버 정보", systemImage: "info.circle")
                }

                ForEach(terminals.sessions) { controller in
                    TabButton(isSelected: terminals.activeSessionID == controller.id) {
                        terminals.activeSessionID = controller.id
                    } label: {
                        SessionTabLabel(controller: controller)
                    } onClose: {
                        if controller.isRunning {
                            pendingClose = controller
                        } else {
                            terminals.close(id: controller.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.bar)
        .alert(
            "연결 중인 세션을 닫을까요?",
            isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
            presenting: pendingClose
        ) { controller in
            Button("닫기", role: .destructive) { terminals.close(id: controller.id) }
            Button("취소", role: .cancel) {}
        } message: { controller in
            Text("\(controller.session.title) (\(controller.session.destination))의 ssh 연결이 종료됩니다.")
        }
    }
}

private struct SessionTabLabel: View {
    let controller: TerminalSessionController

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(controller.isRunning ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(controller.session.title)
                .lineLimit(1)
            if controller.session.isProduction {
                Text("PROD")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
            }
        }
        .help("\(controller.session.title) — \(controller.session.destination)")
    }
}

private struct TabButton<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Content
    var onClose: (() -> Void)?

    @ViewState private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: action) {
                label()
                    .font(.callout)
                    .padding(.leading, 8)
                    .padding(.trailing, onClose == nil ? 8 : 0)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isSelected || isHovering ? 1 : 0.4)
                .padding(.trailing, 4)
                .help("탭 닫기")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : (isHovering ? Color.primary.opacity(0.06) : .clear))
        )
        .onHover { isHovering = $0 }
    }
}

extension TabButton {
    init(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Content) {
        self.init(isSelected: isSelected, action: action, label: label, onClose: nil)
    }

    init(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Content, onClose: @escaping () -> Void) {
        self.isSelected = isSelected
        self.action = action
        self.label = label
        self.onClose = onClose
    }
}

// MARK: - 터미널 세션 화면

struct TerminalSessionView: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    let controller: TerminalSessionController

    @ViewState private var isReconnecting = false
    @ViewState private var reconnectError: String?
    @ViewState private var pendingProductionTarget: ConnectionTarget?

    var body: some View {
        VStack(spacing: 0) {
            if controller.session.isProduction {
                Rectangle().fill(.red).frame(height: 3)
            }
            TerminalHostView(terminalView: controller.terminalView)
                .padding(8)
                .background(Color(nsColor: TerminalSessionController.background))
            if case .exited(let code) = controller.status {
                exitBar(code: code)
            }
        }
        .navigationTitle("\(controller.session.title) — \(controller.session.destination)")
        .productionConfirmation(target: $pendingProductionTarget, accountLabel: state.accountLabel(for:)) { target in
            Task { await finishReconnect(target, confirmed: true) }
        }
    }

    private func exitBar(code: Int32?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "stop.circle")
                Text(exitMessage(code: code))
                Spacer()
                if isReconnecting {
                    ProgressView().controlSize(.small)
                }
                switch controller.session.kind {
                case .ssh:
                    Button("다시 연결") { Task { await reconnect() } }
                        .disabled(isReconnecting)
                        .help("캐시된 IP로 다시 접속합니다. IP가 바뀌었다면 서버 정보에서 \"다시 조회\"를 먼저 누르세요")
                case .awsLogin(let awsProfile):
                    Button("로그인 다시 시도") { Task { await retryLogin(awsProfile) } }
                        .disabled(isReconnecting)
                }
                Button("탭 닫기") { terminals.close(id: controller.id) }
            }
            if let reconnectError {
                Text(reconnectError)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func exitMessage(code: Int32?) -> String {
        if case .awsLogin = controller.session.kind {
            return "로그인이 완료되지 않았습니다" + (code.map { " (종료 코드 \($0))" } ?? "")
        }
        return code.map { "세션이 종료되었습니다 (종료 코드 \($0))" } ?? "세션이 종료되었습니다"
    }

    /// 같은 탭에서 로그인 명령을 다시 실행한다. 성공 시 처리는 처음 열 때 정한 그대로 유지된다.
    private func retryLogin(_ awsProfile: String) async {
        isReconnecting = true
        reconnectError = nil
        defer { isReconnecting = false }
        do {
            terminals.replace(id: controller.id, with: try await state.loginSession(for: awsProfile))
        } catch {
            reconnectError = Self.describe(error)
        }
    }

    private func reconnect() async {
        isReconnecting = true
        reconnectError = nil
        defer { isReconnecting = false }
        guard let profileID = controller.session.profileID else { return }
        do {
            let target = try state.prepareConnection(for: profileID)
            if state.requiresProductionConfirmation(for: target.profile) {
                pendingProductionTarget = target
            } else {
                await finishReconnect(target, confirmed: false)
            }
        } catch {
            reconnectError = Self.describe(error)
        }
    }

    private func finishReconnect(_ target: ConnectionTarget, confirmed: Bool) async {
        do {
            if case .embedded(let session) = try await state.connect(target, productionConfirmed: confirmed, terminal: .embedded) {
                terminals.replace(id: controller.id, with: session)
            }
        } catch {
            reconnectError = Self.describe(error)
        }
    }

    static func describe(_ error: any Error) -> String {
        let localized = error as? LocalizedError
        return [localized?.errorDescription ?? "알 수 없는 오류가 발생했습니다.", localized?.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

/// 자격 증명이 만료/없을 때 내장 터미널 탭에서 AWS CLI 로그인을 실행하는 버튼.
/// 로그인에 성공하면 탭이 닫히고 `retry`가 실행된다.
struct AWSLoginButton: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    let awsProfile: String
    let retry: @MainActor () async -> Void
    var onOpen: () -> Void = {}

    @ViewState private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task { await openLogin() }
            } label: {
                Label("AWS 로그인 (\(awsProfile))", systemImage: "person.badge.key")
            }
            .help("내장 터미널에서 AWS CLI 로그인을 실행하고, 완료되면 다시 조회합니다")
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func openLogin() async {
        errorMessage = nil
        do {
            let session = try await state.loginSession(for: awsProfile)
            terminals.openLogin(session, isLoggedIn: { [state, awsProfile] in await state.isLoggedIn(awsProfile: awsProfile) },
                                onSuccess: retry)
            onOpen()
        } catch {
            errorMessage = TerminalSessionView.describe(error)
        }
    }
}

/// 보관소가 소유한 터미널 뷰를 화면에 붙인다.
/// 화면에서 빠질 때는 떼어내기만 하고 프로세스는 종료하지 않는다.
struct TerminalHostView: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if terminalView.superview !== container { attach(to: container) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        terminalView.removeFromSuperview()
        terminalView.frame = container.bounds
        terminalView.autoresizingMask = [.width, .height]
        container.addSubview(terminalView)
        let view = terminalView
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}

// MARK: - Production 확인 (상세 화면과 다시 연결에서 공용)

extension View {
    func productionConfirmation(target: Binding<ConnectionTarget?>, accountLabel: @escaping (String) -> String,
                                onConfirm: @escaping (ConnectionTarget) -> Void) -> some View {
        alert(
            "Production 서버에 접속합니다",
            isPresented: Binding(get: { target.wrappedValue != nil }, set: { if !$0 { target.wrappedValue = nil } }),
            presenting: target.wrappedValue
        ) { target in
            Button("접속", role: .destructive) { onConfirm(target) }
            Button("취소", role: .cancel) {}
        } message: { target in
            Text("""
            서버: \(target.profile.displayName)
            환경: \(target.profile.environment)
            계정: \(accountLabel(target.profile.accountID)) (\(target.profile.accountID))
            리전: \(target.profile.region)
            인스턴스: \(target.profile.instanceID)
            접속 주소: \(target.address ?? "-") (\(target.instance.lastFetchedAt.formatted(.relative(presentation: .named))) 조회)
            """)
        }
    }
}
