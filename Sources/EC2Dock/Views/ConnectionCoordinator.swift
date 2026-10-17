import AppKit
import EC2DockCore
import Observation
import SwiftUI

/// 서버 목록(더블클릭·Return·우클릭)과 상세 화면이 함께 쓰는 접속 흐름.
/// Production 확인 창, 접속 설정 시트, 목록에서 난 오류 알림은 ContentView가 한 번만 띄운다.
@MainActor
@Observable
final class ConnectionCoordinator {
    enum Source {
        case list
        case detail
    }

    /// 터미널 실행이 실패했을 때 대체 실행(FR-015)에 쓰는 마지막 시도
    struct Attempt {
        let target: ConnectionTarget
        let confirmed: Bool
        let terminal: TerminalApp
    }

    struct Feedback {
        enum Kind {
            case success(String)
            case failure(ConnectionError)
        }

        let kind: Kind
        let attempt: Attempt?
    }

    struct PendingConfirmation {
        let target: ConnectionTarget
        let terminal: TerminalApp?
        let source: Source
    }

    /// 목록에서 시작한 동작의 오류 (상세 화면이 보이지 않을 수 있어 알림으로 보여준다)
    struct ListAlert {
        let profileID: String
        let title: String
        let message: String
        let attempt: Attempt?
    }

    private let state: AppState
    private let terminals: TerminalSessionStore

    private(set) var connectingIDs: Set<String> = []
    private(set) var feedback: [String: Feedback] = [:]
    var pendingConfirmation: PendingConfirmation?
    /// 접속 설정 시트를 열 서버
    var editingProfileID: String?
    var listAlert: ListAlert?

    init(state: AppState, terminals: TerminalSessionStore) {
        self.state = state
        self.terminals = terminals
    }

    func defaultTerminal(for profileID: String) -> TerminalApp {
        TerminalApp(rawValue: state.localSettings(for: profileID).terminalIdentifier) ?? .iTerm2
    }

    // MARK: 접속

    /// `terminal`이 nil이면 서버 설정의 터미널로 연다.
    func connect(profileID: String, terminal: TerminalApp?, source: Source) async {
        feedback[profileID] = nil
        do {
            let target = try state.prepareConnection(for: profileID)
            if state.requiresProductionConfirmation(for: target.profile) {
                pendingConfirmation = PendingConfirmation(target: target, terminal: terminal, source: source)
            } else {
                await perform(target, confirmed: false, terminal: terminal, source: source)
            }
        } catch {
            report(.failure(error), attempt: nil, profileID: profileID, source: source)
        }
    }

    func confirmPending() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        Task { await perform(pending.target, confirmed: true, terminal: pending.terminal, source: pending.source) }
    }

    func perform(_ target: ConnectionTarget, confirmed: Bool, terminal: TerminalApp?, source: Source) async {
        let profileID = target.profile.id
        let app = terminal ?? TerminalApp(rawValue: target.settings.terminalIdentifier) ?? .iTerm2
        connectingIDs.insert(profileID)
        defer { connectingIDs.remove(profileID) }
        do {
            switch try await state.connect(target, productionConfirmed: confirmed, terminal: app) {
            case .external(let message):
                report(.success(message), attempt: nil, profileID: profileID, source: source)
            case .embedded(let session):
                // 메인 창에 새 터미널 탭을 열고 바로 보여준다.
                terminals.open(session)
                feedback[profileID] = nil
            }
        } catch {
            let connectionError = (error as? ConnectionError) ?? .launchFailed(error.localizedDescription)
            let canFallBack: Bool
            switch connectionError {
            case .terminalUnavailable, .automationPermissionDenied, .launchFailed: canFallBack = true
            default: canFallBack = false
            }
            report(.failure(connectionError), attempt: canFallBack ? Attempt(target: target, confirmed: confirmed, terminal: app) : nil,
                   profileID: profileID, source: source)
        }
    }

    private func report(_ kind: Feedback.Kind, attempt: Attempt?, profileID: String, source: Source) {
        feedback[profileID] = Feedback(kind: kind, attempt: attempt)
        guard source == .list, case .failure(let error) = kind else { return }
        listAlert = ListAlert(
            profileID: profileID,
            title: "\(state.profile(id: profileID)?.displayName ?? "서버")에 접속하지 못했습니다",
            message: TerminalErrorText.describe(error),
            attempt: attempt)
    }

    // MARK: 목록 동작

    func refreshInstance(profileID: String) async {
        do {
            try await state.refreshInstance(id: profileID)
        } catch {
            listAlert = ListAlert(profileID: profileID, title: "다시 조회하지 못했습니다",
                                  message: TerminalErrorText.describe(error), attempt: nil)
        }
    }

    /// SSH 명령을 클립보드에 복사한다. 접속할 수 없는 상태면 이유를 알린다.
    @discardableResult
    func copyCommand(profileID: String, source: Source) -> Bool {
        do {
            let target = try state.prepareConnection(for: profileID)
            Self.copy(try state.commandLine(for: target))
            return true
        } catch {
            if source == .list {
                listAlert = ListAlert(profileID: profileID, title: "명령을 만들 수 없습니다",
                                      message: TerminalErrorText.describe(error), attempt: nil)
            } else {
                feedback[profileID] = Feedback(kind: .failure((error as? ConnectionError) ?? .launchFailed("")), attempt: nil)
            }
            return false
        }
    }

    @discardableResult
    func copyCommand(for attempt: Attempt) -> Bool {
        guard let command = try? state.commandLine(for: attempt.target) else { return false }
        Self.copy(command)
        return true
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
