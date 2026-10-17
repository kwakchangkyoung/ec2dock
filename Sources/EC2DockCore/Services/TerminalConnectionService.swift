import Foundation

/// 검증된 대상으로 SSH 명령을 만들어 외부 터미널에서 실행하거나, 내장 터미널 세션으로 넘긴다.
/// Direct SSH와 Bastion SSH를 지원한다. SSM은 아직 지원하지 않는다.
/// 접속 명령 전체나 키 경로를 로그로 남기지 않는다.
public struct TerminalConnectionService: ConnectionService {
    private let builder: SSHCommandBuilder
    private let launcher: any TerminalLauncher

    public init(builder: SSHCommandBuilder = SSHCommandBuilder(), launcher: any TerminalLauncher = AppleScriptTerminalLauncher()) {
        self.builder = builder
        self.launcher = launcher
    }

    public func connect(_ target: ConnectionTarget, in terminal: TerminalApp, preferNewTab: Bool) async throws -> ConnectionOutcome {
        let command = try builder.command(for: target)
        var destination = "\(target.profile.sshUsername)@\(target.address ?? "")"
        if let bastion = target.bastion {
            destination += " (경유 \(bastion.profile.displayName))"
        }
        guard terminal.isExternal else {
            return .embedded(EmbeddedTerminalSession(kind: .ssh(profileID: target.profile.id), title: target.profile.displayName,
                                                     destination: destination,
                                                     isProduction: target.profile.isProduction, command: command))
        }
        do {
            try await launcher.launch(command, in: terminal, newTab: preferNewTab)
        } catch let error as TerminalLaunchError {
            switch error {
            case .appNotInstalled(let app): throw ConnectionError.terminalUnavailable(app)
            case .automationPermissionDenied: throw ConnectionError.automationPermissionDenied(terminal)
            case .launchFailed(let message): throw ConnectionError.launchFailed(message)
            }
        }
        return .external(message: "\(terminal.displayName)에서 접속을 시작했습니다: \(destination)")
    }
}
