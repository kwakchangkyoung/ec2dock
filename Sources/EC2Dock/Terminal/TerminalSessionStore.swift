import AppKit
import EC2DockCore
import Observation
import SwiftTerm

/// 메인 창 안에서 열린 내장 터미널 탭과 분할 칸들.
/// 터미널 뷰(와 ssh 프로세스)는 SwiftUI 화면 수명과 분리해 여기서 보관하므로,
/// 탭·칸·서버를 바꿔도 세션이 끊기지 않고 사용자가 칸이나 탭을 닫을 때만 종료된다.
@MainActor
@Observable
final class TerminalSessionStore {
    /// 분할 요청. 접속 준비(Production 확인 포함)는 화면(TerminalTabView)이 처리한다.
    struct SplitRequest: Equatable {
        let id = UUID()
        let tabID: UUID
        let paneID: UUID
        let profileID: String
        let axis: SplitAxis
    }

    private(set) var tabs: [TerminalTabLayout] = []
    private(set) var controllers: [UUID: TerminalSessionController] = [:]
    /// nil이면 "서버 정보" 탭
    var activeTabID: UUID?
    var pendingSplit: SplitRequest?
    /// 연결 중인 칸을 단축키로 닫으려 할 때 확인을 받는다.
    var pendingClosePaneID: UUID?

    /// 로그인 탭이 성공적으로 끝났을 때 돌아갈 화면과 다시 시도할 작업
    private struct LoginContext {
        let returnTo: UUID?
        let isLoggedIn: @MainActor () async -> Bool
        let onSuccess: @MainActor () async -> Void
    }
    @ObservationIgnored private var loginContexts: [UUID: LoginContext] = [:]
    @ObservationIgnored private var mouseMonitor: Any?

    /// 터미널 탭을 보는 동안 사이드바와 목록을 접는다 (ContentView가 열 표시와 맞춘다).
    var isFocusMode = false
    /// 내장 터미널 글꼴·색상. 바뀌면 열린 모든 칸에 바로 적용한다.
    var appearance = TerminalAppearance.standard {
        didSet {
            guard appearance != oldValue else { return }
            controllers.values.forEach { $0.apply(appearance) }
        }
    }
    /// 터미널 찾기 막대 (⌘F)
    var isFindBarVisible = false
    var findQuery = ""
    /// 메인 창. ⌘W를 이 창에서만 가로챈다.
    @ObservationIgnored weak var mainWindow: NSWindow?

    @ObservationIgnored private var keyMonitor: Any?

    init() {
        // SwiftTerm 뷰의 포커스 변화는 밖에서 알 수 없어, 클릭한 위치로 어느 칸인지 판별한다.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.focusPane(clickedBy: event) }
            return event
        }
        // ⌘W가 메인 창(과 그 안의 모든 ssh 세션)을 바로 닫지 않게 한다.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleCloseShortcut(event) ?? false }
            return consumed ? nil : event
        }
    }

    isolated deinit {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    // MARK: 세션 보호

    /// 연결 중인 ssh·로그인 세션 수 (종료·창 닫기 확인에 사용)
    var runningSessionCount: Int {
        controllers.values.filter(\.isRunning).count
    }

    /// 메인 창에서 ⌘W:
    /// - 터미널 탭을 보고 있으면 포커스된 칸을 닫는다 (연결 중이면 확인).
    /// - 서버 정보를 보고 있는데 연결 중인 세션이 있으면, 창을 닫을지 확인한다.
    /// 가로챘으면 true (기본 동작인 창 닫기를 막는다).
    private func handleCloseShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w",
              let window = event.window, window === mainWindow else { return false }
        if activeTab != nil {
            requestCloseFocusedPane()
            return true
        }
        guard runningSessionCount > 0 else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "연결 중인 터미널 \(runningSessionCount)개가 있습니다"
        alert.informativeText = "창을 닫으면 모든 ssh 연결이 끊깁니다."
        alert.addButton(withTitle: "창 닫기")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.closeAllTabs()
                window?.close()
            }
        }
        return true
    }

    func closeAllTabs() {
        for tab in tabs { closeTab(id: tab.id) }
    }

    // MARK: 찾기 (⌘F)

    func showFindBar() {
        guard activeTab != nil else { return }
        isFindBarVisible = true
    }

    func hideFindBar() {
        isFindBarVisible = false
        guard let tab = activeTab, let view = controllers[tab.focusedPaneID]?.terminalView else { return }
        view.selectNone()
        // 찾기를 마치면 다시 터미널에 입력할 수 있게 한다.
        view.window?.makeFirstResponder(view)
    }

    /// 포커스된 칸에서 다음/이전 결과를 찾는다. 찾으면 선택하고 그 위치로 스크롤한다.
    @discardableResult
    func find(backwards: Bool = false) -> Bool {
        guard let tab = activeTab, let view = controllers[tab.focusedPaneID]?.terminalView, !findQuery.isEmpty else {
            return false
        }
        return backwards ? view.findPrevious(findQuery) : view.findNext(findQuery)
    }

    // MARK: 조회

    var activeTab: TerminalTabLayout? {
        tabs.first { $0.id == activeTabID }
    }

    func controller(id: UUID) -> TerminalSessionController? {
        controllers[id]
    }

    func tab(containing paneID: UUID) -> TerminalTabLayout? {
        tabs.first { $0.contains(paneID) }
    }

    /// 해당 서버에 열린 ssh 세션 (목록 표시와 "터미널로 이동"에 사용)
    func sessions(for profileID: String) -> [TerminalSessionController] {
        tabs.flatMap(\.root.paneIDs).compactMap { controllers[$0] }.filter { $0.session.profileID == profileID }
    }

    /// 포커스된 칸이 ssh 세션이면 같은 서버로 분할할 수 있다.
    var canSplit: Bool {
        guard let tab = activeTab else { return false }
        return controllers[tab.focusedPaneID]?.session.profileID != nil
    }

    // MARK: 열기·닫기

    /// 새 탭으로 연다.
    func open(_ session: EmbeddedTerminalSession) {
        addController(for: session)
        let tab = TerminalTabLayout(firstPane: session.id)
        tabs.append(tab)
        activeTabID = tab.id
    }

    /// 지금 탭의 `paneID` 옆에 분할로 연다.
    func insertSplit(_ session: EmbeddedTerminalSession, besides paneID: UUID, axis: SplitAxis) {
        guard let index = tabs.firstIndex(where: { $0.contains(paneID) }) else {
            open(session)
            return
        }
        addController(for: session)
        tabs[index].root = tabs[index].root.inserting(session.id, besides: paneID, axis: axis)
        tabs[index].focusedPaneID = session.id
        activeTabID = tabs[index].id
    }

    /// 다시 연결/다시 로그인: 같은 칸 자리에 새 세션을 넣는다.
    func replace(id: UUID, with session: EmbeddedTerminalSession) {
        let context = loginContexts.removeValue(forKey: id)
        if let context { loginContexts[session.id] = context }
        if let index = tabs.firstIndex(where: { $0.contains(id) }) {
            controllers.removeValue(forKey: id)?.terminate()
            addController(for: session)
            tabs[index].root = tabs[index].root.replacing(id, with: session.id)
            tabs[index].focusedPaneID = session.id
            activeTabID = tabs[index].id
        } else {
            open(session)
        }
        // 로그인 다시 시도라면 완료 확인도 다시 시작한다.
        if let context { watchLogin(id: session.id, isLoggedIn: context.isLoggedIn) }
    }

    /// 칸 하나를 닫는다. 마지막 칸이면 탭도 닫는다.
    func close(id: UUID) {
        loginContexts[id] = nil
        controllers.removeValue(forKey: id)?.terminate()
        guard let index = tabs.firstIndex(where: { $0.contains(id) }) else { return }
        if let remaining = tabs[index].root.removing(id) {
            tabs[index].root = remaining
            if tabs[index].focusedPaneID == id {
                tabs[index].focusedPaneID = remaining.paneIDs.first ?? id
            }
        } else {
            removeTab(at: index)
        }
    }

    /// 탭과 그 안의 모든 칸을 닫는다.
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        for paneID in tabs[index].root.paneIDs {
            loginContexts[paneID] = nil
            controllers.removeValue(forKey: paneID)?.terminate()
        }
        removeTab(at: index)
    }

    /// 닫은 탭이 보이던 탭이면 이웃 탭(없으면 "서버 정보")으로 옮긴다.
    private func removeTab(at index: Int) {
        let removed = tabs.remove(at: index)
        guard activeTabID == removed.id else { return }
        activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
    }

    private func addController(for session: EmbeddedTerminalSession) {
        let controller = TerminalSessionController(session: session, appearance: appearance)
        controller.onExit = { [weak self] id, exitCode in self?.handleExit(id: id, exitCode: exitCode) }
        controllers[session.id] = controller
    }

    // MARK: 포커스·이동 (단축키)

    /// 칸을 보이게 하고 포커스를 준다.
    func show(paneID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.contains(paneID) }) else { return }
        tabs[index].focusedPaneID = paneID
        activeTabID = tabs[index].id
    }

    func focusAdjacentPane(offset: Int) {
        guard let tab = activeTab else { return }
        show(paneID: tab.pane(after: tab.focusedPaneID, offset: offset))
    }

    func selectAdjacentTab(offset: Int) {
        activeTabID = TerminalTabNavigation.adjacent(to: activeTabID, offset: offset, tabs: tabs.map(\.id))
    }

    /// ⌘←/⌘→: 글자 입력 칸(검색창 등)에 커서가 있으면 원래 동작대로 줄 처음/끝으로 옮기고, 아니면 터미널 탭을 옮긴다.
    func selectAdjacentTabOrMoveCursor(offset: Int) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            offset < 0 ? editor.moveToBeginningOfLine(nil) : editor.moveToEndOfLine(nil)
            return
        }
        selectAdjacentTab(offset: offset)
    }

    /// ⌘1~⌘9: n번째 터미널 탭, ⌘0: 서버 정보
    func selectTab(number: Int) {
        if let target = TerminalTabNavigation.tab(number: number, tabs: tabs.map(\.id)) {
            activeTabID = target
        }
    }

    func requestSplit(axis: SplitAxis) {
        guard let tab = activeTab, let profileID = controllers[tab.focusedPaneID]?.session.profileID else {
            NSSound.beep()
            return
        }
        pendingSplit = SplitRequest(tabID: tab.id, paneID: tab.focusedPaneID, profileID: profileID, axis: axis)
    }

    /// 단축키로 포커스된 칸을 닫는다. 연결 중이면 확인을 받는다.
    func requestCloseFocusedPane() {
        guard let tab = activeTab else { return }
        if controllers[tab.focusedPaneID]?.isRunning == true {
            pendingClosePaneID = tab.focusedPaneID
        } else {
            close(id: tab.focusedPaneID)
        }
    }

    private func focusPane(clickedBy event: NSEvent) {
        guard let tab = activeTab, tab.root.paneIDs.count > 1 else { return }
        for paneID in tab.root.paneIDs {
            guard let view = controllers[paneID]?.terminalView, view.window === event.window else { continue }
            if view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                if tab.focusedPaneID != paneID { show(paneID: paneID) }
                return
            }
        }
    }

    // MARK: AWS 로그인 탭

    /// AWS 로그인 탭을 열고, 로그인이 끝나면 탭을 닫고 원래 화면으로 돌아가 `onSuccess`를 실행한다.
    /// 로그인 명령이 종료 코드 0으로 끝나거나, `isLoggedIn` 확인이 성공하면 끝난 것으로 본다
    /// (로그인 후에도 aws 명령이 바로 끝나지 않는 경우 대비).
    func openLogin(
        _ session: EmbeddedTerminalSession,
        isLoggedIn: @escaping @MainActor () async -> Bool,
        onSuccess: @escaping @MainActor () async -> Void
    ) {
        loginContexts[session.id] = LoginContext(returnTo: activeTabID, isLoggedIn: isLoggedIn, onSuccess: onSuccess)
        open(session)
        watchLogin(id: session.id, isLoggedIn: isLoggedIn)
    }

    private func watchLogin(id: UUID, isLoggedIn: @escaping @MainActor () async -> Bool) {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                // 칸이 닫혔거나 다시 시도로 교체되면 그만둔다.
                guard let self, let controller = self.controller(id: id), controller.isRunning,
                      self.loginContexts[id] != nil else { return }
                if await isLoggedIn() {
                    self.completeLogin(id: id)
                    return
                }
            }
        }
    }

    private func handleExit(id: UUID, exitCode: Int32?) {
        guard exitCode == 0 else { return }
        completeLogin(id: id)
    }

    private func completeLogin(id: UUID) {
        guard let context = loginContexts.removeValue(forKey: id) else { return }
        close(id: id)
        if let returnTo = context.returnTo, tabs.contains(where: { $0.id == returnTo }) {
            activeTabID = returnTo
        } else if context.returnTo == nil {
            activeTabID = nil
        }
        Task { await context.onSuccess() }
    }
}

@MainActor
@Observable
final class TerminalSessionController: Identifiable {
    enum Status: Equatable {
        case running
        case exited(Int32?)
    }

    let session: EmbeddedTerminalSession
    private(set) var status: Status = .running
    @ObservationIgnored let terminalView: LocalProcessTerminalView
    @ObservationIgnored private var processDelegate: ProcessDelegate?
    @ObservationIgnored private var exitWatcher: Task<Void, Never>?
    /// 프로세스가 끝나면 알린다. 종료 코드는 일반 종료면 0~255, 시그널로 끝나면 nil.
    @ObservationIgnored var onExit: ((UUID, Int32?) -> Void)?

    nonisolated var id: UUID { session.id }
    var isRunning: Bool { status == .running }

    init(session: EmbeddedTerminalSession, appearance: TerminalAppearance = .standard) {
        self.session = session
        terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        apply(appearance)

        let delegate = ProcessDelegate { [weak self] rawStatus in
            self?.markExited(rawStatus: rawStatus)
        }
        processDelegate = delegate
        terminalView.processDelegate = delegate
        // 셸을 거치지 않고 실행 파일 + 인자 배열로 pty에서 실행한다.
        terminalView.startProcess(executable: session.command.executable, args: session.command.arguments,
                                  environment: Self.environment())
        watchForExit(pid: terminalView.process.shellPid)
    }

    /// SwiftTerm은 감시를 시작하기 전에 끝난 프로세스의 종료를 놓칠 수 있다.
    /// 보조로 0.5초마다 직접 확인해, 끝났으면 회수하고 종료로 처리한다.
    private func watchForExit(pid: pid_t) {
        guard pid > 0 else { return }
        exitWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isRunning else { return }
                var rawStatus: Int32 = 0
                if waitpid(pid, &rawStatus, WNOHANG) == pid {
                    self.markExited(rawStatus: rawStatus)
                    return
                }
            }
        }
    }

    /// 종료 처리는 한 번만 한다. `waitpid` 원시 상태를 일반 종료 코드로 바꾼다.
    private func markExited(rawStatus: Int32?) {
        guard isRunning else { return }
        let exitCode = rawStatus.flatMap { raw in (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : nil }
        status = .exited(exitCode)
        exitWatcher?.cancel()
        onExit?(id, exitCode)
    }

    /// 터미널 주변 여백에도 같은 배경색을 쓴다.
    private(set) var backgroundColor = TerminalAppearance.standard.colors.background

    func apply(_ appearance: TerminalAppearance) {
        let colors = appearance.colors
        terminalView.font = NSFont.monospacedSystemFont(ofSize: CGFloat(appearance.fontSize), weight: .regular)
        terminalView.nativeBackgroundColor = colors.background
        terminalView.nativeForegroundColor = colors.foreground
        terminalView.caretColor = .controlAccentColor
        terminalView.selectedTextBackgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35)
        backgroundColor = colors.background
    }

    func terminate() {
        if isRunning { terminalView.terminate() }
    }

    /// 터미널 기본값에 ssh-agent 소켓과 PATH만 더한다. 자격 증명 값은 넘기지 않는다.
    private static func environment() -> [String] {
        var variables = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let current = ProcessInfo.processInfo.environment
        // ssh-agent 소켓, PATH, AWS CLI 설정 파일 위치만 전달한다. 자격 증명 환경 변수는 넘기지 않는다.
        for key in ["SSH_AUTH_SOCK", "PATH", "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE"] {
            if let value = current[key] { variables.append("\(key)=\(value)") }
        }
        return variables
    }
}

private final class ProcessDelegate: NSObject, LocalProcessTerminalViewDelegate {
    private let onExit: @MainActor @Sendable (Int32?) -> Void

    init(onExit: @escaping @MainActor @Sendable (Int32?) -> Void) {
        self.onExit = onExit
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // LocalProcess는 기본적으로 메인 큐에서 콜백한다.
        let onExit = self.onExit
        MainActor.assumeIsolated { onExit(exitCode) }
    }
}

/// 내장 터미널 글꼴 크기와 색상
struct TerminalAppearance: Equatable {
    var fontSize: Double
    var theme: TerminalTheme
    /// `.system` 테마일 때 지금 시스템이 다크 모드인지
    var systemIsDark: Bool

    static let standard = TerminalAppearance(fontSize: AppPreferences.defaultTerminalFontSize, theme: .dark, systemIsDark: true)

    var colors: (background: NSColor, foreground: NSColor) {
        let dark = theme == .dark || (theme == .system && systemIsDark)
        return dark
            ? (NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1), NSColor(calibratedWhite: 0.9, alpha: 1))
            : (NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.97, alpha: 1), NSColor(calibratedWhite: 0.13, alpha: 1))
    }
}
