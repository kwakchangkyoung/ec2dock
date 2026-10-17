import Foundation
import Testing
@testable import EC2DockCore

private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

private func makeTarget(
    type: ConnectionType = .directSSH,
    username: String = "ec2-user",
    port: Int = 22,
    address: String? = "203.0.113.25",
    keyPath: String? = nil,
    timeout: Int = 10,
    terminal: TerminalApp = .iTerm2
) -> ConnectionTarget {
    let profile = ServerProfile(accountID: "111111111111", accountAlias: "acme", region: "ap-northeast-2",
                                instanceID: "i-0123456789abcdef0", displayName: "web", environment: "Production",
                                connectionType: type, sshUsername: username, sshPort: port,
                                bastionProfileID: type == .bastionSSH ? "x" : nil,
                                createdAt: fixedDate, updatedAt: fixedDate)
    let instance = EC2Instance(accountID: "111111111111", region: "ap-northeast-2", instanceID: "i-0123456789abcdef0",
                               state: "running", publicIPAddress: address, privateIPAddress: "10.0.0.5", lastFetchedAt: fixedDate)
    let settings = LocalConnectionSettings(profileID: profile.id, awsCLIProfileName: "acme", sshKeyPath: keyPath,
                                           terminalIdentifier: terminal.rawValue, connectTimeoutSeconds: timeout)
    return ConnectionTarget(profile: profile, instance: instance, address: address, settings: settings)
}

@Suite("SSHCommandBuilder")
struct SSHCommandBuilderTests {
    let builder = SSHCommandBuilder { _ in .ok }

    @Test func directSSHWithoutKey() throws {
        let command = try builder.command(for: makeTarget(port: 2222, timeout: 15))
        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments == [
            "-o", "ConnectTimeout=15",
            "-o", "HostKeyAlias=i-0123456789abcdef0",
            "-p", "2222",
            "--", "ec2-user@203.0.113.25",
        ])
    }

    @Test func directSSHWithKeyExpandsTilde() throws {
        let command = try builder.command(for: makeTarget(keyPath: "~/.ssh/web.pem"))
        let expanded = NSHomeDirectory() + "/.ssh/web.pem"
        #expect(Array(command.arguments.prefix(4)) == ["-i", expanded, "-o", "IdentitiesOnly=yes"])
    }

    /// 호스트 키 검증을 끄는 옵션을 절대 넣지 않는다 (설계서 8.5).
    @Test func neverDisablesHostKeyChecking() throws {
        let line = try builder.command(for: makeTarget(keyPath: "~/.ssh/web.pem")).shellCommandLine
        #expect(!line.contains("StrictHostKeyChecking"))
        #expect(!line.contains("UserKnownHostsFile"))
        #expect(!line.contains("/dev/null"))
    }

    @Test func ipv6AddressIsAccepted() throws {
        let command = try builder.command(for: makeTarget(address: "2001:db8::10"))
        #expect(command.arguments.last == "ec2-user@2001:db8::10")
    }

    @Test(arguments: ["example.com", "-oProxyCommand=sh", "203.0.113.25 -v", ""])
    func nonIPAddressIsRejected(_ address: String) {
        #expect(throws: ConnectionError.noPublicIP) { try builder.command(for: makeTarget(address: address)) }
    }

    @Test func injectionInUsernameIsRejected() {
        #expect(throws: ConnectionError.self) { try builder.command(for: makeTarget(username: "-oProxyCommand=sh")) }
    }

    @Test func ssmIsNotSupportedYet() {
        #expect(throws: ConnectionError.unsupportedConnectionType(.ssm)) {
            try builder.command(for: makeTarget(type: .ssm))
        }
    }

    @Test func bastionTargetWithoutHopFails() {
        #expect(throws: ConnectionError.bastionNotConfigured) {
            try builder.command(for: makeTarget(type: .bastionSSH, address: "10.0.0.5"))
        }
    }

    @Test func keyFileProblemsAreReported() {
        let missing = SSHCommandBuilder { _ in .missing }
        let open = SSHCommandBuilder { _ in .tooOpen }
        #expect(throws: ConnectionError.keyFileNotFound("~/.ssh/a.pem")) {
            try missing.command(for: makeTarget(keyPath: "~/.ssh/a.pem"))
        }
        #expect(throws: ConnectionError.keyFilePermissionsTooOpen("~/.ssh/a.pem")) {
            try open.command(for: makeTarget(keyPath: "~/.ssh/a.pem"))
        }
    }

    @Test func realKeyFilePermissionCheck() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EC2DockKeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key.pem")
        try Data("not a real key".utf8).write(to: key)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)
        #expect(SSHCommandBuilder.checkKeyFile(key.path) == .tooOpen)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        #expect(SSHCommandBuilder.checkKeyFile(key.path) == .ok)
        let symlink = directory.appendingPathComponent("link.pem")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: key)
        #expect(SSHCommandBuilder.checkKeyFile(symlink.path) == .ok)
        #expect(SSHCommandBuilder.checkKeyFile(directory.path) == .missing)
        #expect(SSHCommandBuilder.checkKeyFile(directory.appendingPathComponent("none").path) == .missing)
    }
}

@Suite("Shell quoting")
struct ShellQuotingTests {
    /// 인용된 명령을 실제 shell이 해석해도 원래 인자 그대로 전달되는지 확인한다.
    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func quotedCommandRoundTripsThroughShell(_ shell: String) async throws {
        let tricky = ["plain", "with space", "it's", "$(id)", "`id`", "a;b", "x|y", "\"q\"", "~/k.pem", "*", "\\back"]
        let command = TerminalCommand(executable: "/usr/bin/printf", arguments: ["%s\\n"] + tricky)
        let result = try await ProcessCommandRunner().run(
            URL(fileURLWithPath: shell), arguments: ["-c", command.shellCommandLine],
            environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(5))
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == tricky.map { $0 + "\n" }.joined())
    }

    @Test func safeArgumentsStayReadable() {
        let command = TerminalCommand(executable: "/usr/bin/ssh", arguments: ["-p", "22", "--", "ec2-user@203.0.113.25"])
        #expect(command.shellCommandLine == "/usr/bin/ssh -p 22 -- ec2-user@203.0.113.25")
    }
}

@Suite("AppleScriptTerminalLauncher")
struct AppleScriptTerminalLauncherTests {
    let runner = FakeRunner()
    let command = TerminalCommand(executable: "/usr/bin/ssh", arguments: ["--", "ec2-user@203.0.113.25"])

    private func launcher(installed: Bool = true) -> AppleScriptTerminalLauncher {
        AppleScriptTerminalLauncher(runner: runner, isInstalled: { _ in installed })
    }

    /// 명령은 스크립트 본문이 아닌 argv로만 전달된다 (AppleScript 주입 방지).
    @Test(arguments: [TerminalApp.iTerm2, .terminal])
    func passesCommandOnlyAsArgument(_ app: TerminalApp) async throws {
        await runner.respond(to: ["-e"])
        try await launcher().launch(command, in: app)

        let arguments = try #require(await runner.calls.first)
        #expect(arguments.last == command.shellCommandLine)
        let script = arguments.dropLast()
        #expect(!script.joined().contains("203.0.113.25"))
        #expect(script.contains("tell application id \"\(app.rawValue)\""))
        #expect(script.contains { $0.contains("item 1 of argv") })
    }

    @Test func notInstalledDoesNotRunOsascript() async {
        await #expect(throws: TerminalLaunchError.appNotInstalled(.iTerm2)) {
            try await launcher(installed: false).launch(command, in: .iTerm2)
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test func automationDenialIsRecognized() async {
        await runner.respond(to: ["-e"], stderr: "execution error: Not authorized to send Apple events to iTerm. (-1743)", exitCode: 1)
        await #expect(throws: TerminalLaunchError.automationPermissionDenied) {
            try await launcher().launch(command, in: .iTerm2)
        }
    }
}

@Suite("TerminalConnectionService")
struct TerminalConnectionServiceTests {
    let builder = SSHCommandBuilder { _ in .ok }

    @Test func launchesBuiltCommandInRequestedTerminal() async throws {
        let launcher = MockTerminalLauncher()
        let service = TerminalConnectionService(builder: builder, launcher: launcher)
        let target = makeTarget()

        let outcome = try await service.connect(target, in: .terminal)

        guard case .external(let message) = outcome else {
            Issue.record("expected external outcome")
            return
        }
        #expect(message.contains("Terminal"))
        let launched = await launcher.launched
        #expect(launched.count == 1)
        #expect(launched.first?.app == .terminal)
        #expect(launched.first?.command == (try builder.command(for: target)))
    }

    @Test func missingTerminalMapsToFallbackError() async {
        let service = TerminalConnectionService(builder: builder, launcher: MockTerminalLauncher(installedApps: [.terminal]))
        await #expect(throws: ConnectionError.terminalUnavailable(.iTerm2)) {
            try await service.connect(makeTarget(), in: .iTerm2)
        }
    }

    @Test func unsupportedTypeNeverLaunches() async {
        let launcher = MockTerminalLauncher()
        let service = TerminalConnectionService(builder: builder, launcher: launcher)
        await #expect(throws: ConnectionError.unsupportedConnectionType(.ssm)) {
            try await service.connect(makeTarget(type: .ssm), in: .iTerm2)
        }
        #expect(await launcher.launched.isEmpty)
    }
}

@Suite("Embedded terminal")
struct EmbeddedTerminalTests {
    let builder = SSHCommandBuilder { _ in .ok }

    @Test func embeddedReturnsSessionWithoutLaunchingExternalApp() async throws {
        let launcher = MockTerminalLauncher()
        let service = TerminalConnectionService(builder: builder, launcher: launcher)
        let target = makeTarget()

        let outcome = try await service.connect(target, in: .embedded)

        guard case .embedded(let session) = outcome else {
            Issue.record("expected embedded outcome")
            return
        }
        #expect(session.command == (try builder.command(for: target)))
        #expect(session.destination == "ec2-user@203.0.113.25")
        #expect(session.isProduction)
        #expect(await launcher.launched.isEmpty)
    }

    @Test func embeddedStillValidatesTarget() async {
        let service = TerminalConnectionService(builder: builder, launcher: MockTerminalLauncher())
        await #expect(throws: ConnectionError.noPublicIP) {
            try await service.connect(makeTarget(address: "-oProxyCommand=sh"), in: .embedded)
        }
    }

    @Test func appleScriptLauncherRejectsEmbedded() async {
        let runner = FakeRunner()
        let launcher = AppleScriptTerminalLauncher(runner: runner, isInstalled: { _ in true })
        await #expect(throws: TerminalLaunchError.self) {
            try await launcher.launch(TerminalCommand(executable: "/usr/bin/ssh", arguments: []), in: .embedded)
        }
        #expect(await runner.calls.isEmpty)
    }

    /// 샘플 모드에서는 가짜 IP로 ssh를 실행하지 않는다.
    @Test func sampleModeEmbeddedSessionDoesNotRunSSH() async throws {
        let outcome = try await MockConnectionService().connect(makeTarget(), in: .embedded)
        guard case .embedded(let session) = outcome else {
            Issue.record("expected embedded outcome")
            return
        }
        #expect(session.command.executable == "/bin/echo")
    }
}


// MARK: - Bastion

private func makeBastionTarget(
    targetKey: String? = "~/.ssh/id_rsa",
    bastionKey: String? = nil,
    bastionUser: String = "ec2-user",
    bastionPort: Int = 22,
    targetAddress: String = "10.0.31.74"
) -> ConnectionTarget {
    let bastionProfile = ServerProfile(accountID: "111111111111", accountAlias: "acme", region: "ap-northeast-2",
                                       instanceID: "i-0aaaaaaaaaaaaaaa1", displayName: "bastion",
                                       sshUsername: bastionUser, sshPort: bastionPort, createdAt: fixedDate, updatedAt: fixedDate)
    let bastionInstance = EC2Instance(accountID: "111111111111", region: "ap-northeast-2", instanceID: "i-0aaaaaaaaaaaaaaa1",
                                      state: "running", publicIPAddress: "198.51.100.10", lastFetchedAt: fixedDate)
    let bastionSettings = LocalConnectionSettings(profileID: bastionProfile.id, awsCLIProfileName: "acme",
                                                  sshKeyPath: bastionKey, connectTimeoutSeconds: 7)
    let profile = ServerProfile(accountID: "111111111111", accountAlias: "acme", region: "ap-northeast-2",
                                instanceID: "i-0123456789abcdef0", displayName: "app", connectionType: .bastionSSH,
                                bastionProfileID: bastionProfile.id, createdAt: fixedDate, updatedAt: fixedDate)
    let instance = EC2Instance(accountID: "111111111111", region: "ap-northeast-2", instanceID: "i-0123456789abcdef0",
                               state: "running", privateIPAddress: targetAddress, lastFetchedAt: fixedDate)
    let settings = LocalConnectionSettings(profileID: profile.id, awsCLIProfileName: "acme", sshKeyPath: targetKey)
    let hop = BastionHop(profile: bastionProfile, instance: bastionInstance, address: "198.51.100.10", settings: bastionSettings)
    return ConnectionTarget(profile: profile, instance: instance, address: targetAddress, settings: settings, bastion: hop)
}

@Suite("Bastion SSH command")
struct BastionCommandTests {
    let builder = SSHCommandBuilder { _ in .ok }

    /// 일반적인 `ssh -i ~/.ssh/id_rsa -J ec2-user@198.51.100.10 ec2-user@10.0.31.74`에 해당한다.
    @Test func matchesUsersJumpCommand() throws {
        let command = try builder.command(for: makeBastionTarget())
        let key = NSHomeDirectory() + "/.ssh/id_rsa"
        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments == [
            "-i", key, "-o", "IdentitiesOnly=yes",
            "-o", "ConnectTimeout=10",
            "-o", "HostKeyAlias=i-0123456789abcdef0",
            "-p", "22",
            "-o", "ProxyCommand=/usr/bin/ssh -o ConnectTimeout=7 -o HostKeyAlias=i-0aaaaaaaaaaaaaaa1 -p 22 -W 10.0.31.74:22 -- ec2-user@198.51.100.10",
            "--", "ec2-user@10.0.31.74",
        ])
    }

    @Test func eachHopUsesItsOwnKeyUserAndPort() throws {
        let command = try builder.command(for: makeBastionTarget(targetKey: nil, bastionKey: "~/keys/bastion key.pem",
                                                                 bastionUser: "admin", bastionPort: 2222))
        let proxy = try #require(command.arguments.first { $0.hasPrefix("ProxyCommand=") })
        #expect(proxy.contains("-i '\(NSHomeDirectory())/keys/bastion key.pem' -o IdentitiesOnly=yes"))
        #expect(proxy.contains("-p 2222"))
        #expect(proxy.hasSuffix("-- admin@198.51.100.10"))
        #expect(!command.arguments.contains("-i"))   // 대상 구간 키 미지정 → ssh 기본값
    }

    @Test func ipv6TargetIsBracketedForForwarding() throws {
        let command = try builder.command(for: makeBastionTarget(targetAddress: "fd00::10"))
        let proxy = try #require(command.arguments.first { $0.hasPrefix("ProxyCommand=") })
        #expect(proxy.contains("-W '[fd00::10]:22'"))
    }

    @Test func neverDisablesHostKeyChecking() throws {
        let line = try builder.command(for: makeBastionTarget(bastionKey: "~/.ssh/b.pem")).shellCommandLine
        #expect(!line.contains("StrictHostKeyChecking"))
        #expect(!line.contains("UserKnownHostsFile"))
    }

    @Test func percentInKeyPathIsEscapedForSSHTokens() {
        let value = SSHCommandBuilder.proxyCommandValue(["/usr/bin/ssh", "-i", "/keys/100%.pem"])
        #expect(value == "/usr/bin/ssh -i /keys/100%%.pem")
    }

    /// ProxyCommand 문자열을 셸이 해석해도 각 인자가 그대로 전달된다 (주입 방지).
    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func proxyCommandRoundTripsThroughShell(_ shell: String) async throws {
        let tricky = ["a b", "it's", "$(id)", "`id`", "x;y", "\"q\""]
        let value = SSHCommandBuilder.proxyCommandValue(["/usr/bin/printf", "%s\n"] + tricky)
        // ssh는 %%를 %로 바꾼 뒤 셸로 실행한다.
        let shellLine = value.replacingOccurrences(of: "%%", with: "%")
        let result = try await ProcessCommandRunner().run(URL(fileURLWithPath: shell), arguments: ["-c", "exec \(shellLine)"],
                                                          environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(5))
        #expect(String(decoding: result.stdout, as: UTF8.self) == tricky.map { $0 + "\n" }.joined())
    }

    /// 실제 OpenSSH가 명령을 어떻게 해석하는지 `ssh -G`로 확인한다 (접속하지 않음).
    @Test func openSSHParsesGeneratedCommand() async throws {
        let command = try builder.command(for: makeBastionTarget(bastionKey: "~/keys/bastion key.pem"))
        var arguments = command.arguments
        arguments.insert(contentsOf: ["-G", "-F", "/dev/null"], at: 0)
        let result = try await ProcessCommandRunner().run(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: arguments,
                                                          environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                                          timeout: .seconds(5))
        let output = String(decoding: result.stdout, as: UTF8.self)
        #expect(result.exitCode == 0)
        #expect(output.contains("hostname 10.0.31.74"))
        #expect(output.contains("user ec2-user"))
        #expect(output.contains("hostkeyalias i-0123456789abcdef0"))
        #expect(output.contains("proxycommand /usr/bin/ssh -i '\(NSHomeDirectory())/keys/bastion key.pem' -o IdentitiesOnly=yes"))
        #expect(output.contains("-W 10.0.31.74:22 -- ec2-user@198.51.100.10"))
    }
}
