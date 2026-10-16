import AppKit
import Foundation

/// iTerm2 / Terminal을 AppleScript로 열어 명령을 실행한다 (설계서 8.4).
/// 스크립트 본문은 고정 문자열이고, 실행할 명령은 `osascript`의 인자(argv)로만 전달한다.
/// 따라서 명령 내용이 AppleScript 코드로 해석될 여지가 없다.
public struct AppleScriptTerminalLauncher: TerminalLauncher {
    private let runner: any CommandRunner
    private let isInstalled: @Sendable (TerminalApp) async -> Bool

    public init(
        runner: any CommandRunner = ProcessCommandRunner(),
        isInstalled: @escaping @Sendable (TerminalApp) async -> Bool = AppleScriptTerminalLauncher.isInstalledInWorkspace
    ) {
        self.runner = runner
        self.isInstalled = isInstalled
    }

    public func isAvailable(_ app: TerminalApp) async -> Bool {
        await isInstalled(app)
    }

    public func launch(_ command: TerminalCommand, in app: TerminalApp) async throws {
        guard app.isExternal else { throw TerminalLaunchError.launchFailed("내장 터미널은 외부 앱으로 실행하지 않습니다.") }
        guard await isInstalled(app) else { throw TerminalLaunchError.appNotInstalled(app) }

        let result: CommandResult
        do {
            // 처음 실행 시 macOS 자동화 권한 확인 창이 떠서 사용자 응답을 기다릴 수 있다.
            result = try await runner.run(
                URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: Self.scriptArguments(for: app) + [command.shellCommandLine],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: .seconds(120))
        } catch {
            throw TerminalLaunchError.launchFailed("osascript를 실행하지 못했습니다.")
        }

        guard result.exitCode == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            // -1743: errAEEventNotPermitted (자동화 권한 거부)
            if stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not authorized") {
                throw TerminalLaunchError.automationPermissionDenied
            }
            throw TerminalLaunchError.launchFailed(AWSCLIErrorMapper.summary(of: stderr))
        }
    }

    /// `osascript -e ... -e ...` 인자. 명령은 run 핸들러의 `item 1 of argv`로 받는다.
    static func scriptArguments(for app: TerminalApp) -> [String] {
        let lines: [String]
        switch app {
        case .iTerm2:
            lines = [
                "on run argv",
                "tell application id \"\(TerminalApp.iTerm2.rawValue)\"",
                "activate",
                "set newWindow to (create window with default profile)",
                "tell current session of newWindow to write text (item 1 of argv)",
                "end tell",
                "end run",
            ]
        case .terminal:
            lines = [
                "on run argv",
                "tell application id \"\(TerminalApp.terminal.rawValue)\"",
                "activate",
                "do script (item 1 of argv)",
                "end tell",
                "end run",
            ]
        case .embedded:
            lines = []
        }
        return lines.flatMap { ["-e", $0] }
    }

    public static let isInstalledInWorkspace: @Sendable (TerminalApp) async -> Bool = { app in
        await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.rawValue) != nil
        }
    }
}
