import Foundation

/// 터미널에서 실행할 명령. 항상 실행 파일과 인자 배열로 구성하며,
/// 사용자 입력을 shell 문자열로 이어 붙이지 않는다 (설계서 10.3).
public struct TerminalCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum TerminalLaunchError: Error, Equatable, Sendable {
    case appNotInstalled(TerminalApp)
    case automationPermissionDenied
    case launchFailed(String)
}

/// iTerm2 / Terminal 실행 계층. Phase 3에서 AppleScript 구현으로 대체한다.
public protocol TerminalLauncher: Sendable {
    func isAvailable(_ app: TerminalApp) async -> Bool
    /// `newTab`이 true면 열린 창이 있을 때 새 탭으로 연다 (iTerm2만 지원, 그 외에는 새 창).
    func launch(_ command: TerminalCommand, in app: TerminalApp, newTab: Bool) async throws
}

extension TerminalLauncher {
    public func launch(_ command: TerminalCommand, in app: TerminalApp) async throws {
        try await launch(command, in: app, newTab: false)
    }
}
