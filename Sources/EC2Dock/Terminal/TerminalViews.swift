import AppKit
import EC2DockCore
import SwiftTerm
import SwiftUI

/// 메인 창의 상세 영역. 열린 터미널이 있으면 위에 탭 막대를 두고
/// "서버 정보"와 각 터미널 탭(분할 가능) 사이를 오간다.
struct DetailArea: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    let selectedServerID: String?

    var body: some View {
        VStack(spacing: 0) {
            if !terminals.tabs.isEmpty {
                SessionTabBar()
                Divider()
            }
            if let tab = terminals.activeTab {
                TerminalTabView(tabID: tab.id)
                    .id(tab.id)
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
    @ViewState private var pendingCloseTab: TerminalTabLayout?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    TabButton(isSelected: terminals.activeTabID == nil) {
                        terminals.activeTabID = nil
                    } label: {
                        Label("서버 정보", systemImage: "info.circle")
                    }
                    .help("서버 정보 (⌘0)")

                    ForEach(Array(terminals.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabButton(isSelected: terminals.activeTabID == tab.id) {
                            terminals.activeTabID = tab.id
                        } label: {
                            SessionTabLabel(tab: tab, number: index + 1)
                        } onClose: {
                            let running = tab.root.paneIDs.contains { terminals.controller(id: $0)?.isRunning == true }
                            if running {
                                pendingCloseTab = tab
                            } else {
                                terminals.closeTab(id: tab.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }

            if terminals.activeTab != nil {
                Divider().frame(height: 18)
                HStack(spacing: 2) {
                    Button { terminals.showFindBar() } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("터미널에서 찾기 (⌘F)")
                    .accessibilityLabel("터미널에서 찾기")
                    Button { terminals.requestSplit(axis: .horizontal) } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .help("좌우로 분할 (⌘D)")
                    .accessibilityLabel("좌우로 분할")
                    .disabled(!terminals.canSplit)
                    Button { terminals.requestSplit(axis: .vertical) } label: {
                        Image(systemName: "rectangle.split.1x2")
                    }
                    .help("위아래로 분할 (⇧⌘D)")
                    .accessibilityLabel("위아래로 분할")
                    .disabled(!terminals.canSplit)
                    Button { terminals.isFocusMode.toggle() } label: {
                        Image(systemName: terminals.isFocusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .help(terminals.isFocusMode ? "목록 다시 보기 (⇧⌘F)" : "터미널 넓게 보기 (⇧⌘F)")
                    .accessibilityLabel(terminals.isFocusMode ? "목록 다시 보기" : "터미널 넓게 보기")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
            }
        }
        .background(.bar)
        .alert(
            "연결 중인 탭을 닫을까요?",
            isPresented: Binding(get: { pendingCloseTab != nil }, set: { if !$0 { pendingCloseTab = nil } }),
            presenting: pendingCloseTab
        ) { tab in
            Button("닫기", role: .destructive) { terminals.closeTab(id: tab.id) }
            Button("취소", role: .cancel) {}
        } message: { tab in
            Text("이 탭의 터미널 \(tab.root.paneIDs.count)개의 연결이 모두 종료됩니다.")
        }
    }
}

private struct SessionTabLabel: View {
    @Environment(TerminalSessionStore.self) private var terminals
    let tab: TerminalTabLayout
    let number: Int

    var body: some View {
        let controller = terminals.controller(id: tab.focusedPaneID)
        let paneCount = tab.root.paneIDs.count
        let anyRunning = tab.root.paneIDs.contains { terminals.controller(id: $0)?.isRunning == true }
        let anyProduction = tab.root.paneIDs.contains { terminals.controller(id: $0)?.session.isProduction == true }
        HStack(spacing: 5) {
            Circle()
                .fill(anyRunning ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(controller?.session.title ?? "터미널")
                .lineLimit(1)
            if paneCount > 1 {
                Text("\(paneCount)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .background(Color.secondary.opacity(0.2), in: Capsule())
                    .help("분할된 터미널 \(paneCount)개")
            }
            if anyProduction {
                Text("PROD")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
            }
        }
        .help(number <= 9 ? "\(controller?.session.destination ?? "") (⌘\(number))" : controller?.session.destination ?? "")
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
                .accessibilityLabel("탭 닫기")
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

// MARK: - 터미널 탭 (분할)

/// 탭 하나의 분할 배치를 그린다. 분할 요청이 오면 같은 서버로 새 접속을 만들어 칸을 추가한다.
struct TerminalTabView: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    let tabID: UUID

    @ViewState private var productionSplit: (target: ConnectionTarget, request: TerminalSessionStore.SplitRequest)?
    @ViewState private var splitError: String?

    var body: some View {
        Group {
            if let tab = terminals.tabs.first(where: { $0.id == tabID }) {
                VStack(spacing: 0) {
                    if terminals.isFindBarVisible {
                        TerminalFindBar()
                        Divider()
                    }
                    PaneTreeView(node: tab.root, tab: tab)
                }
                .navigationTitle(navigationTitle(tab))
            }
        }
        .task(id: terminals.pendingSplit) {
            guard let request = terminals.pendingSplit, request.tabID == tabID else { return }
            terminals.pendingSplit = nil
            await startSplit(request)
        }
        .productionConfirmation(
            target: Binding(get: { productionSplit?.target }, set: { if $0 == nil { productionSplit = nil } }),
            accountLabel: state.accountLabel(for:)
        ) { target in
            guard let request = productionSplit?.request else { return }
            Task { await finishSplit(target, request: request, confirmed: true) }
        }
        .alert("분할하지 못했습니다", isPresented: Binding(get: { splitError != nil }, set: { if !$0 { splitError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(splitError ?? "")
        }
        .alert(
            "연결 중인 터미널을 닫을까요?",
            isPresented: Binding(get: { terminals.pendingClosePaneID != nil }, set: { if !$0 { terminals.pendingClosePaneID = nil } })
        ) {
            Button("닫기", role: .destructive) {
                if let id = terminals.pendingClosePaneID { terminals.close(id: id) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 칸의 ssh 연결이 종료됩니다.")
        }
    }

    private func navigationTitle(_ tab: TerminalTabLayout) -> String {
        guard let session = terminals.controller(id: tab.focusedPaneID)?.session else { return "터미널" }
        return "\(session.title) — \(session.destination)"
    }

    private func startSplit(_ request: TerminalSessionStore.SplitRequest) async {
        do {
            let target = try state.prepareConnection(for: request.profileID)
            if state.requiresProductionConfirmation(for: target.profile) {
                productionSplit = (target, request)
            } else {
                await finishSplit(target, request: request, confirmed: false)
            }
        } catch {
            splitError = TerminalErrorText.describe(error)
        }
    }

    private func finishSplit(_ target: ConnectionTarget, request: TerminalSessionStore.SplitRequest, confirmed: Bool) async {
        do {
            if case .embedded(let session) = try await state.connect(target, productionConfirmed: confirmed, terminal: .embedded) {
                terminals.insertSplit(session, besides: request.paneID, axis: request.axis)
            }
        } catch {
            splitError = TerminalErrorText.describe(error)
        }
    }
}

/// 분할 트리를 재귀적으로 그린다. 칸 사이 경계는 드래그로 크기를 바꿀 수 있다.
private struct PaneTreeView: View {
    let node: PaneNode
    let tab: TerminalTabLayout

    var body: some View {
        switch node {
        case .pane(let id):
            TerminalPaneView(paneID: id, isFocused: tab.focusedPaneID == id, isSplit: tab.root.paneIDs.count > 1)
        case .split(_, let axis, let children):
            if axis == .horizontal {
                HSplitView {
                    ForEach(children) { child in
                        AnyView(PaneTreeView(node: child, tab: tab)).frame(minWidth: 160)
                    }
                }
            } else {
                VSplitView {
                    ForEach(children) { child in
                        AnyView(PaneTreeView(node: child, tab: tab)).frame(minHeight: 90)
                    }
                }
            }
        }
    }
}

// MARK: - 터미널 칸

struct TerminalPaneView: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    let paneID: UUID
    let isFocused: Bool
    let isSplit: Bool

    @ViewState private var isReconnecting = false
    @ViewState private var reconnectError: String?
    @ViewState private var pendingProductionTarget: ConnectionTarget?

    var body: some View {
        if let controller = terminals.controller(id: paneID) {
            content(controller)
        }
    }

    private func content(_ controller: TerminalSessionController) -> some View {
        VStack(spacing: 0) {
            if isSplit {
                paneHeader(controller)
            }
            if controller.session.isProduction {
                Rectangle().fill(.red).frame(height: 3)
            }
            TerminalHostView(terminalView: controller.terminalView, isFocused: isFocused && !terminals.isFindBarVisible)
                .padding(8)
                .background(Color(nsColor: controller.backgroundColor))
            if case .exited(let code) = controller.status {
                exitBar(controller, code: code)
            }
        }
        .overlay {
            // 분할 중에는 포커스된 칸을 강조색 테두리로 표시한다.
            if isSplit && isFocused {
                Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2).allowsHitTesting(false)
            }
        }
        .productionConfirmation(target: $pendingProductionTarget, accountLabel: state.accountLabel(for:)) { target in
            Task { await finishReconnect(controller, target, confirmed: true) }
        }
    }

    private func paneHeader(_ controller: TerminalSessionController) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(controller.isRunning ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(controller.session.title).font(.caption.weight(.semibold)).lineLimit(1)
            Text(controller.session.destination).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button {
                if controller.isRunning {
                    terminals.pendingClosePaneID = paneID
                } else {
                    terminals.close(id: paneID)
                }
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("이 칸 닫기 (⌘W)")
            .accessibilityLabel("이 칸 닫기")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isFocused ? Color.accentColor.opacity(0.15) : Color.clear)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { terminals.show(paneID: paneID) }
    }

    private func exitBar(_ controller: TerminalSessionController, code: Int32?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "stop.circle")
                Text(exitMessage(controller, code: code))
                Spacer()
                if isReconnecting {
                    ProgressView().controlSize(.small)
                }
                switch controller.session.kind {
                case .ssh:
                    Button("다시 연결") { Task { await reconnect(controller) } }
                        .disabled(isReconnecting)
                        .help("캐시된 IP로 다시 접속합니다. IP가 바뀌었다면 서버 정보에서 \"다시 조회\"를 먼저 누르세요")
                case .awsLogin(let awsProfile):
                    Button("로그인 다시 시도") { Task { await retryLogin(awsProfile) } }
                        .disabled(isReconnecting)
                }
                Button(isSplit ? "칸 닫기" : "탭 닫기") { terminals.close(id: paneID) }
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

    private func exitMessage(_ controller: TerminalSessionController, code: Int32?) -> String {
        if case .awsLogin = controller.session.kind {
            return "로그인이 완료되지 않았습니다" + (code.map { " (종료 코드 \($0))" } ?? "")
        }
        return code.map { "세션이 종료되었습니다 (종료 코드 \($0))" } ?? "세션이 종료되었습니다"
    }

    /// 같은 칸에서 로그인 명령을 다시 실행한다. 성공 시 처리는 처음 열 때 정한 그대로 유지된다.
    private func retryLogin(_ awsProfile: String) async {
        isReconnecting = true
        reconnectError = nil
        defer { isReconnecting = false }
        do {
            terminals.replace(id: paneID, with: try await state.loginSession(for: awsProfile))
        } catch {
            reconnectError = TerminalErrorText.describe(error)
        }
    }

    private func reconnect(_ controller: TerminalSessionController) async {
        isReconnecting = true
        reconnectError = nil
        defer { isReconnecting = false }
        guard let profileID = controller.session.profileID else { return }
        do {
            let target = try state.prepareConnection(for: profileID)
            if state.requiresProductionConfirmation(for: target.profile) {
                pendingProductionTarget = target
            } else {
                await finishReconnect(controller, target, confirmed: false)
            }
        } catch {
            reconnectError = TerminalErrorText.describe(error)
        }
    }

    private func finishReconnect(_ controller: TerminalSessionController, _ target: ConnectionTarget, confirmed: Bool) async {
        do {
            if case .embedded(let session) = try await state.connect(target, productionConfirmed: confirmed, terminal: .embedded) {
                terminals.replace(id: controller.id, with: session)
            }
        } catch {
            reconnectError = TerminalErrorText.describe(error)
        }
    }
}

enum TerminalErrorText {
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
            errorMessage = TerminalErrorText.describe(error)
        }
    }
}

/// 보관소가 소유한 터미널 뷰를 화면에 붙인다.
/// 화면에서 빠질 때는 떼어내기만 하고 프로세스는 종료하지 않는다.
/// 붙을 때와 포커스된 칸이 될 때만 키보드 입력을 받도록 first responder로 만든다.
/// (화면이 갱신될 때마다 포커스를 가져오면 찾기 막대나 검색창에 입력하는 중에 포커스를 빼앗는다.)
struct TerminalHostView: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView
    var isFocused = true

    final class Coordinator {
        var wasFocused = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        context.coordinator.wasFocused = isFocused
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if terminalView.superview !== container {
            attach(to: container)
        } else if isFocused && !context.coordinator.wasFocused {
            focusIfNeeded()
        }
        context.coordinator.wasFocused = isFocused
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        terminalView.removeFromSuperview()
        terminalView.frame = container.bounds
        terminalView.autoresizingMask = [.width, .height]
        container.addSubview(terminalView)
        focusIfNeeded()
    }

    private func focusIfNeeded() {
        guard isFocused else { return }
        let view = terminalView
        DispatchQueue.main.async {
            if let window = view.window, window.firstResponder !== view {
                window.makeFirstResponder(view)
            }
        }
    }
}

// MARK: - Production 확인 (상세 화면과 다시 연결에서 공용)

extension View {
    func productionConfirmation(target: Binding<ConnectionTarget?>, accountLabel: @escaping (String) -> String,
                                title: String = "Production 서버에 접속합니다", confirmLabel: String = "접속",
                                onConfirm: @escaping (ConnectionTarget) -> Void) -> some View {
        alert(
            title,
            isPresented: Binding(get: { target.wrappedValue != nil }, set: { if !$0 { target.wrappedValue = nil } }),
            presenting: target.wrappedValue
        ) { target in
            Button(confirmLabel, role: .destructive) { onConfirm(target) }
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

// MARK: - 찾기 막대

/// 포커스된 칸의 출력에서 찾는다. Return: 다음, ⇧Return: 이전, Esc: 닫기
private struct TerminalFindBar: View {
    @Environment(TerminalSessionStore.self) private var terminals
    @FocusState private var isFieldFocused: Bool
    @ViewState private var notFound = false

    var body: some View {
        @Bindable var terminals = terminals
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("터미널에서 찾기", text: $terminals.findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($isFieldFocused)
                .onSubmit { search(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand { terminals.hideFindBar() }
            Button { search(backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("이전 결과 (⇧⌘G)")
                .accessibilityLabel("이전 결과")
            Button { search(backwards: false) } label: { Image(systemName: "chevron.down") }
                .help("다음 결과 (⌘G)")
                .accessibilityLabel("다음 결과")
            if notFound {
                Text("결과 없음").font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Button("완료") { terminals.hideFindBar() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .onAppear { isFieldFocused = true }
        .onChange(of: terminals.findQuery) { notFound = false }
    }

    private func search(backwards: Bool) {
        notFound = !terminals.findQuery.isEmpty && !terminals.find(backwards: backwards)
    }
}
