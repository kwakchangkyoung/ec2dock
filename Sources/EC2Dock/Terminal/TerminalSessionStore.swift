import AppKit
import EC2DockCore
import Observation
import SwiftTerm

/// 메인 창 안에서 열린 내장 터미널 세션들.
/// 터미널 뷰(와 ssh 프로세스)는 SwiftUI 화면 수명과 분리해 여기서 보관하므로,
/// 탭이나 서버를 바꿔도 세션이 끊기지 않고 사용자가 탭을 닫을 때만 종료된다.
@MainActor
@Observable
final class TerminalSessionStore {
    private(set) var sessions: [TerminalSessionController] = []
    /// nil이면 "서버 정보" 탭
    var activeSessionID: UUID?

    /// 로그인 탭이 성공적으로 끝났을 때 돌아갈 화면과 다시 시도할 작업
    private struct LoginContext {
        let returnTo: UUID?
        let isLoggedIn: @MainActor () async -> Bool
        let onSuccess: @MainActor () async -> Void
    }
    @ObservationIgnored private var loginContexts: [UUID: LoginContext] = [:]

    func open(_ session: EmbeddedTerminalSession) {
        let controller = TerminalSessionController(session: session)
        controller.onExit = { [weak self] id, exitCode in self?.handleExit(id: id, exitCode: exitCode) }
        sessions.append(controller)
        activeSessionID = session.id
    }

    /// AWS 로그인 탭을 열고, 로그인이 끝나면 탭을 닫고 원래 화면으로 돌아가 `onSuccess`를 실행한다.
    /// 로그인 명령이 종료 코드 0으로 끝나거나, `isLoggedIn` 확인이 성공하면 끝난 것으로 본다
    /// (로그인 후에도 aws 명령이 바로 끝나지 않는 경우 대비).
    func openLogin(
        _ session: EmbeddedTerminalSession,
        isLoggedIn: @escaping @MainActor () async -> Bool,
        onSuccess: @escaping @MainActor () async -> Void
    ) {
        loginContexts[session.id] = LoginContext(returnTo: activeSessionID, isLoggedIn: isLoggedIn, onSuccess: onSuccess)
        open(session)
        watchLogin(id: session.id, isLoggedIn: isLoggedIn)
    }

    private func watchLogin(id: UUID, isLoggedIn: @escaping @MainActor () async -> Bool) {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                // 탭이 닫혔거나 다시 시도로 교체되면 그만둔다.
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
        if let returnTo = context.returnTo, controller(id: returnTo) != nil {
            activeSessionID = returnTo
        }
        Task { await context.onSuccess() }
    }

    func controller(id: UUID) -> TerminalSessionController? {
        sessions.first { $0.id == id }
    }

    /// 해당 서버에 열린 ssh 세션 (목록 표시와 "터미널로 이동"에 사용)
    func sessions(for profileID: String) -> [TerminalSessionController] {
        sessions.filter { $0.session.profileID == profileID }
    }

    /// 다시 연결/다시 로그인: 같은 탭 위치에 새 세션을 넣는다.
    func replace(id: UUID, with session: EmbeddedTerminalSession) {
        let context = loginContexts.removeValue(forKey: id)
        if let context { loginContexts[session.id] = context }
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].terminate()
            let controller = TerminalSessionController(session: session)
            controller.onExit = { [weak self] id, exitCode in self?.handleExit(id: id, exitCode: exitCode) }
            sessions[index] = controller
            activeSessionID = session.id
        } else {
            open(session)
        }
        // 로그인 다시 시도라면 완료 확인도 다시 시작한다.
        if let context { watchLogin(id: session.id, isLoggedIn: context.isLoggedIn) }
    }

    func close(id: UUID) {
        loginContexts[id] = nil
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].terminate()
        sessions.remove(at: index)
        if activeSessionID == id { activeSessionID = nil }
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

    init(session: EmbeddedTerminalSession) {
        self.session = session
        terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeBackgroundColor = Self.background
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        terminalView.caretColor = .controlAccentColor
        terminalView.selectedTextBackgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35)

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

    /// 터미널 주변 여백에도 같은 색을 쓴다.
    static let background = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)

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
