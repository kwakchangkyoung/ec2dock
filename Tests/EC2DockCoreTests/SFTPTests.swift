import Foundation
import Testing
@testable import EC2DockCore

private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15

private func makeTarget(type: ConnectionType = .directSSH, address: String? = "203.0.113.25",
                        keyPath: String? = nil, environment: String = "") -> ConnectionTarget {
    let profile = ServerProfile(accountID: "111111111111", accountAlias: "acme", region: "ap-northeast-2",
                                instanceID: "i-0123456789abcdef0", displayName: "web", environment: environment,
                                connectionType: type, sshPort: 2222,
                                bastionProfileID: type == .bastionSSH ? "b" : nil,
                                createdAt: fixedDate, updatedAt: fixedDate)
    let instance = EC2Instance(accountID: "111111111111", region: "ap-northeast-2", instanceID: "i-0123456789abcdef0",
                               state: "running", publicIPAddress: address, privateIPAddress: "10.0.0.5", lastFetchedAt: fixedDate)
    let settings = LocalConnectionSettings(profileID: profile.id, awsCLIProfileName: "acme", sshKeyPath: keyPath,
                                           terminalIdentifier: TerminalApp.embedded.rawValue, connectTimeoutSeconds: 10)
    var bastion: BastionHop?
    if type == .bastionSSH {
        let bastionProfile = ServerProfile(accountID: "111111111111", accountAlias: "acme", region: "ap-northeast-2",
                                           instanceID: "i-0bbbbbbbbbbbbbbb1", displayName: "bastion",
                                           createdAt: fixedDate, updatedAt: fixedDate)
        let bastionInstance = EC2Instance(accountID: "111111111111", region: "ap-northeast-2", instanceID: "i-0bbbbbbbbbbbbbbb1",
                                          state: "running", publicIPAddress: "198.51.100.7", lastFetchedAt: fixedDate)
        bastion = BastionHop(profile: bastionProfile, instance: bastionInstance, address: "198.51.100.7",
                             settings: LocalConnectionSettings(profileID: bastionProfile.id, awsCLIProfileName: "acme",
                                                               terminalIdentifier: TerminalApp.embedded.rawValue))
    }
    return ConnectionTarget(profile: profile, instance: instance, address: type == .bastionSSH ? "10.0.0.5" : address,
                            settings: settings, bastion: bastion)
}

@Suite("SFTP 명령 구성")
struct SFTPCommandTests {
    let builder = SSHCommandBuilder { _ in .ok }

    @Test func directSFTPUsesSameHostKeyAliasAndBatchMode() throws {
        let command = try builder.sftpCommand(for: makeTarget(keyPath: "~/.ssh/web.pem"), batchFile: "/tmp/b.txt",
                                              controlPath: "/tmp/ec2dock-501/i-0123456789abcdef0-%C")
        #expect(command.executable == "/usr/bin/sftp")
        #expect(command.arguments == [
            "-i", NSHomeDirectory() + "/.ssh/web.pem", "-o", "IdentitiesOnly=yes",
            "-o", "ConnectTimeout=10",
            "-o", "HostKeyAlias=i-0123456789abcdef0",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/ec2dock-501/i-0123456789abcdef0-%C", "-o", "ControlPersist=60",
            "-P", "2222",
            "-b", "/tmp/b.txt",
            "--", "ec2-user@203.0.113.25",
        ])
    }

    /// 호스트 키 검증을 끄는 옵션을 절대 넣지 않는다 (설계서 8.5).
    @Test func neverDisablesHostKeyChecking() throws {
        let line = try builder.sftpCommand(for: makeTarget(type: .bastionSSH), batchFile: "/tmp/b.txt", controlPath: nil)
            .shellCommandLine
        #expect(!line.contains("StrictHostKeyChecking"))
        #expect(!line.contains("UserKnownHostsFile"))
        #expect(!line.contains("ControlMaster"))
    }

    @Test func bastionUsesProxyCommandToPrivateIP() throws {
        let command = try builder.sftpCommand(for: makeTarget(type: .bastionSSH), batchFile: "/tmp/b.txt", controlPath: nil)
        let proxy = try #require(command.arguments.first { $0.hasPrefix("ProxyCommand=") })
        #expect(proxy.contains("HostKeyAlias=i-0bbbbbbbbbbbbbbb1"))
        #expect(proxy.contains("-W 10.0.0.5:2222"))
        #expect(proxy.contains("ec2-user@198.51.100.7"))
        #expect(command.arguments.last == "ec2-user@10.0.0.5")
    }

    @Test func ipv6DestinationIsBracketed() throws {
        let command = try builder.sftpCommand(for: makeTarget(address: "2001:db8::10"), batchFile: "/tmp/b.txt", controlPath: nil)
        #expect(command.arguments.last == "ec2-user@[2001:db8::10]")
    }

    @Test func ssmIsNotSupported() {
        #expect(throws: ConnectionError.unsupportedConnectionType(.ssm)) {
            try builder.sftpCommand(for: makeTarget(type: .ssm), batchFile: "/tmp/b.txt", controlPath: nil)
        }
    }

    @Test func noPublicIPIsReported() {
        #expect(throws: ConnectionError.noPublicIP) {
            try builder.sftpCommand(for: makeTarget(address: nil), batchFile: "/tmp/b.txt", controlPath: nil)
        }
    }
}

@Suite("SFTP 배치 명령")
struct SFTPBatchTests {
    @Test func quotesPathsAndEscapesDoubleQuotes() throws {
        #expect(try SFTPBatch.quote("/home/ec2-user/my file.txt") == #""/home/ec2-user/my file.txt""#)
        #expect(try SFTPBatch.quote(#"/tmp/a"b"#) == #""/tmp/a\"b""#)
        // 큰따옴표 안에서는 glob 문자가 글자 그대로라 이스케이프하지 않는다.
        #expect(try SFTPBatch.quote("/tmp/star*.txt") == #""/tmp/star*.txt""#)
    }

    /// 서버에서 온 이름으로 다음 명령을 끼워 넣거나 옵션처럼 해석되게 할 수 없다.
    @Test func rejectsInjectionAttempts() {
        #expect(throws: SFTPError.self) { try SFTPBatch.quote("/tmp/x\nrm -rf /") }
        #expect(throws: SFTPError.self) { try SFTPBatch.quote("/tmp/x\r\nput /etc/passwd") }
        #expect(throws: SFTPError.self) { try SFTPBatch.quote("/tmp/a\\b") }
        #expect(throws: SFTPError.self) { try SFTPBatch.quote("-r /etc") }
        #expect(throws: SFTPError.self) { try SFTPBatch.quote("relative/path") }
    }

    @Test func commands() throws {
        #expect(try SFTPBatch.listCommand("/home/ec2-user") == #"ls -lan "/home/ec2-user""#)
        #expect(try SFTPBatch.downloadCommand("/var/log/app", isDirectory: true, to: "/Users/me/Downloads/app")
            == #"get -r "/var/log/app" "/Users/me/Downloads/app""#)
        #expect(try SFTPBatch.uploadCommand("/Users/me/a.zip", isDirectory: false, to: "/home/ec2-user/a.zip")
            == #"put "/Users/me/a.zip" "/home/ec2-user/a.zip""#)
        #expect(try SFTPBatch.makeDirectoryCommand("/home/ec2-user/new folder") == #"mkdir "/home/ec2-user/new folder""#)
    }

    @Test func parsesWorkingDirectory() {
        #expect(SFTPBatch.parseWorkingDirectory("sftp> pwd\nRemote working directory: /home/ec2-user\n") == "/home/ec2-user")
        #expect(SFTPBatch.parseWorkingDirectory("nothing") == nil)
    }

    /// OpenSSH sftp가 실제로 출력한 형식 (폴더 경로가 붙은 이름, 링크 수 "?")
    @Test func parsesRealListing() throws {
        let output = """
        sftp> ls -lan "/home/ec2-user"
        -rw-r--r--    ? 1000     1000            2 Jan 14 10:40 /home/ec2-user/  lead space.txt
        drwxr-xr-x    ? 1000     1000          384 Jan 14 10:40 /home/ec2-user/.
        drwxr-xr-x    ? 1000     1000          544 Jan 14 10:40 /home/ec2-user/..
        -rw-r--r--    ? 1000     1000            2 Jan 14 10:40 /home/ec2-user/.hidden
        drwxr-xr-x    ? 1000     1000           64 Jan 14 10:40 /home/ec2-user/dir one
        lrwxr-xr-x    ? 1000     1000            7 Jan 14 10:40 /home/ec2-user/linkdir
        -rw-r--r--    ? 1000     1000   5368709120 Jan  3  2024 /home/ec2-user/big.iso
        -rw-r--r--    ? 1000     1000            2 Jan 14 10:40 /home/ec2-user/quote"name.txt
        -rw-r--r--    ? 1000     1000            2 Jan 14 10:40 /home/ec2-user/한글 파일.txt
        """
        let entries = SFTPBatch.parseListing(output, now: fixedDate, calendar: Self.utc)
        #expect(entries.map(\.name) == ["  lead space.txt", ".hidden", "dir one", "linkdir", "big.iso", #"quote"name.txt"#, "한글 파일.txt"])
        #expect(entries.map(\.kind) == [.file, .file, .directory, .symlink, .file, .file, .file])
        #expect(entries[4].size == 5_368_709_120)
        #expect(entries[1].isHidden)
        #expect(entries[3].isOpenable)

        let components = Self.utc.dateComponents([.year, .month, .day, .hour, .minute], from: try #require(entries[0].modified))
        #expect(components == DateComponents(year: 2027, month: 1, day: 14, hour: 10, minute: 40))
        #expect(Self.utc.component(.year, from: try #require(entries[4].modified)) == 2024)
    }

    /// 연도가 없는 날짜가 미래가 되면 작년 날짜다 (1월에 본 12월 파일).
    @Test func yearlessFutureDateIsLastYear() throws {
        let entries = SFTPBatch.parseListing("-rw-r--r--    1 0 0 10 Dec 30 23:59 notes.txt", now: fixedDate, calendar: Self.utc)
        #expect(Self.utc.component(.year, from: try #require(entries.first?.modified)) == 2026)
    }

    @Test func ignoresMalformedLines() {
        #expect(SFTPBatch.parseListing("Can't ls: \"/x\" not found\ngarbage line", now: fixedDate).isEmpty)
    }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}

@Suite("SFTP 오류 분류")
struct SFTPErrorMapperTests {
    /// OpenSSH가 실제로 출력한 메시지
    @Test func classifiesRealMessages() {
        #expect(SFTPErrorMapper.map(stderr: "Host key verification failed.\nConnection closed") == .hostKeyUnverified)
        #expect(SFTPErrorMapper.map(stderr: "ec2-user@1.2.3.4: Permission denied (publickey).\nConnection closed") == .authenticationFailed)
        #expect(SFTPErrorMapper.map(stderr: "ssh: connect to host 1.2.3.4 port 22: Connection refused\nConnection closed")
            == .connectionFailed("ssh: connect to host 1.2.3.4 port 22: Connection refused"))
        #expect(SFTPErrorMapper.map(stderr: #"Can't ls: "/nope" not found"#) == .notFound(#"Can't ls: "/nope" not found"#))
        #expect(SFTPErrorMapper.map(stderr: #"remote open("/root/x"): Permission denied"#)
            == .permissionDenied(#"remote open("/root/x"): Permission denied"#))
        #expect(SFTPErrorMapper.map(stderr: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@") == .hostKeyChanged)
    }
}

@Suite("원격·로컬 경로")
struct SFTPPathTests {
    @Test func remotePaths() {
        #expect(RemotePath.join("/home/ec2-user", "app") == "/home/ec2-user/app")
        #expect(RemotePath.join("/", "etc") == "/etc")
        #expect(RemotePath.parent(of: "/home/ec2-user") == "/home")
        #expect(RemotePath.parent(of: "/home") == "/")
        #expect(RemotePath.parent(of: "/") == "/")
        #expect(RemotePath.breadcrumbs(of: "/home/ec2-user").map(\.path) == ["/", "/home", "/home/ec2-user"])
    }

    @Test func validatesNewNames() throws {
        try RemotePath.validateName("new folder")
        for bad in ["", ".", "..", "a/b"] {
            #expect(throws: SFTPError.invalidName(bad)) { try RemotePath.validateName(bad) }
        }
        #expect(throws: SFTPError.self) { try RemotePath.validateName("a\nb") }
    }

    /// 내려받을 때 이 Mac의 파일을 덮어쓰지 않는다.
    @Test func uniqueLocalNames() {
        let folder = URL(fileURLWithPath: "/Users/me/Downloads")
        let existing: Set<String> = ["report.txt", "report (1).txt", "logs", ".env"]
        let exists: (URL) -> Bool = { existing.contains($0.lastPathComponent) }
        #expect(LocalFileNaming.uniqueURL(for: "new.txt", in: folder, exists: exists).lastPathComponent == "new.txt")
        #expect(LocalFileNaming.uniqueURL(for: "report.txt", in: folder, exists: exists).lastPathComponent == "report (2).txt")
        #expect(LocalFileNaming.uniqueURL(for: "logs", in: folder, exists: exists).lastPathComponent == "logs (1)")
        #expect(LocalFileNaming.uniqueURL(for: ".env", in: folder, exists: exists).lastPathComponent == ".env (1)")
    }
}

/// 실행 인자와 그 순간의 배치 파일 내용을 기록한다.
private actor RecordingRunner: CommandRunner {
    private(set) var calls: [(arguments: [String], batch: String, environment: [String: String])] = []
    var result = CommandResult(exitCode: 0, stdout: Data(), stderr: Data())

    func setResult(_ result: CommandResult) { self.result = result }

    func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> CommandResult {
        let batchIndex = try #require(arguments.firstIndex(of: "-b"))
        let batch = (try? String(contentsOfFile: arguments[batchIndex + 1], encoding: .utf8)) ?? ""
        calls.append((arguments, batch, environment))
        return result
    }
}

@Suite("OpenSSHSFTPClient")
struct OpenSSHSFTPClientTests {
    @Test func runsBatchAndCleansUp() async throws {
        let runner = RecordingRunner()
        await runner.setResult(CommandResult(exitCode: 0, stdout: Data("""
        sftp> ls -lan "/srv"
        drwxr-xr-x    ? 0 0 4096 Jan 14 10:40 /srv/www
        """.utf8), stderr: Data()))
        let client = OpenSSHSFTPClient(target: makeTarget(), builder: SSHCommandBuilder { _ in .ok }, runner: runner,
                                       controlDirectory: "/tmp/ec2dock-test", now: { fixedDate })

        let entries = try await client.list("/srv")
        #expect(entries.map(\.name) == ["www"])

        let call = try #require(await runner.calls.first)
        #expect(call.batch == "ls -lan \"/srv\"\n")
        #expect(call.arguments.contains("ControlPath=/tmp/ec2dock-test/i-0123456789abcdef0-%C"))
        #expect(call.environment["LC_ALL"] == "en_US.UTF-8")
        #expect(call.environment["AWS_SECRET_ACCESS_KEY"] == nil)
        // 배치 파일은 끝나면 지운다.
        let batchPath = call.arguments[try #require(call.arguments.firstIndex(of: "-b")) + 1]
        #expect(!FileManager.default.fileExists(atPath: batchPath))
    }

    @Test func mapsFailures() async throws {
        let runner = RecordingRunner()
        await runner.setResult(CommandResult(exitCode: 255, stdout: Data(), stderr: Data("Host key verification failed.\n".utf8)))
        let client = OpenSSHSFTPClient(target: makeTarget(), builder: SSHCommandBuilder { _ in .ok }, runner: runner,
                                       controlDirectory: nil)
        await #expect(throws: SFTPError.hostKeyUnverified) { try await client.homeDirectory() }
        #expect(await runner.calls.first?.arguments.contains { $0.hasPrefix("ControlPath") } == false)
    }

    @Test func rejectsUnsafeNamesBeforeRunning() async {
        let runner = RecordingRunner()
        let client = OpenSSHSFTPClient(target: makeTarget(), builder: SSHCommandBuilder { _ in .ok }, runner: runner,
                                       controlDirectory: nil)
        await #expect(throws: SFTPError.self) { try await client.makeDirectory("/tmp/a\nrm x") }
        #expect(await runner.calls.isEmpty)
    }
}

@Suite("SFTP 연결 재사용 폴더")
struct SFTPControlDirectoryTests {
    @Test func createsPrivateDirectoryAndRejectsOpenOne() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "cm-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let path = try #require(SFTPControlDirectory.prepare(base: base))
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)

        // 다른 사용자도 쓸 수 있게 열린 폴더는 쓰지 않는다.
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: path)
        #expect(SFTPControlDirectory.prepare(base: base) == nil)
    }
}

@MainActor
@Suite("AppState 파일 접근")
struct AppStateFileAccessTests {
    private func makeState() -> AppState {
        AppState(profiles: [], cachedInstances: [], preferences: AppPreferences(),
                 aws: MockAWSDiscoveryService(accounts: [:], instances: []), connectionService: MockConnectionService(),
                 syncService: MockSyncService(), sftpClientFactory: { _ in MockSFTPClient() })
    }

    /// Production 확인은 파일 접근에도 UI를 거치지 않고 강제된다.
    @Test func productionRequiresConfirmation() throws {
        let state = makeState()
        let production = makeTarget(environment: "prod")
        #expect(throws: ConnectionError.productionConfirmationRequired) {
            try state.fileClient(for: production, productionConfirmed: false)
        }
        _ = try state.fileClient(for: production, productionConfirmed: true)
        _ = try state.fileClient(for: makeTarget(), productionConfirmed: false)
    }

    @Test func ssmIsRejected() {
        #expect(throws: ConnectionError.unsupportedConnectionType(.ssm)) {
            try makeState().fileClient(for: makeTarget(type: .ssm), productionConfirmed: true)
        }
    }
}

@Suite("MockSFTPClient")
struct MockSFTPClientTests {
    @Test func browseUploadAndMakeDirectory() async throws {
        let client = MockSFTPClient()
        let home = try await client.homeDirectory()
        #expect(try await client.list(home).contains { $0.name == "app" })

        try await client.makeDirectory(RemotePath.join(home, "new"))
        #expect(try await client.list(RemotePath.join(home, "new")).isEmpty)
        await #expect(throws: SFTPError.self) { try await client.list("/missing") }
    }
}
