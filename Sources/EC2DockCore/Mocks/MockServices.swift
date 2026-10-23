import Foundation

/// 실제 AWS 계정 없이 동작하는 조회 Mock. AWS CLI를 실행하지 않는다.
public actor MockAWSDiscoveryService: AWSDiscoveryService {
    /// AWS CLI 프로필 이름 → 계정 ID
    private var accounts: [String: String]
    private var instances: [EC2Instance]
    private var failure: AWSDiscoveryError?
    private let latency: Duration
    private var activeDescribeCalls = 0
    /// 동시에 실행된 리전 조회의 최대 개수 (동시 조회 제한 확인용)
    public private(set) var maxConcurrentDescribeCalls = 0

    public init(accounts: [String: String], instances: [EC2Instance], latency: Duration = .zero) {
        self.accounts = accounts
        self.instances = instances
        self.latency = latency
    }

    public func setInstances(_ instances: [EC2Instance]) { self.instances = instances }
    public func setFailure(_ failure: AWSDiscoveryError?) { self.failure = failure }

    public func listProfiles() async throws -> [String] {
        try await simulateCall()
        return accounts.keys.sorted()
    }

    public func callerIdentity(profile: String) async throws -> AWSCallerIdentity {
        try await simulateCall()
        let accountID = try account(for: profile)
        return AWSCallerIdentity(accountID: accountID, arn: "arn:aws:iam::\(accountID):user/mock")
    }

    public func describeInstances(profile: String, region: String) async throws -> [EC2Instance] {
        activeDescribeCalls += 1
        maxConcurrentDescribeCalls = max(maxConcurrentDescribeCalls, activeDescribeCalls)
        defer { activeDescribeCalls -= 1 }
        try await simulateCall()
        let accountID = try account(for: profile)
        let now = Date()
        return instances
            .filter { $0.accountID == accountID && $0.region == region }
            .map { var instance = $0; instance.lastFetchedAt = now; return instance }
    }

    public func describeInstance(profile: String, region: String, instanceID: String) async throws -> EC2Instance? {
        try await describeInstances(profile: profile, region: region).first { $0.instanceID == instanceID }
    }

    /// 샘플 모드에서는 실제 명령 대신 안내 문구만 출력하고, 새 프로필을 기존 계정에 연결한다.
    public func addAccountCommand(profile: String, method: AWSAccountSetupMethod) async throws -> TerminalCommand {
        guard InputValidator.isValidAWSProfileName(profile) else { throw AWSDiscoveryError.invalidArgument("프로필 이름") }
        if accounts[profile] == nil { accounts[profile] = SampleData.devAccountID }
        let command = (["aws"] + method.arguments + ["--profile", profile]).joined(separator: " ")
        return TerminalCommand(executable: "/bin/echo", arguments: ["샘플 모드: \(command) 을(를) 실행했다고 가정합니다."])
    }

    /// 샘플 모드에서는 실제 로그인 대신 안내 문구만 출력하고, 실패 상태를 해제한다(로그인 성공 흉내).
    public func loginCommand(profile: String) async throws -> TerminalCommand {
        _ = try account(for: profile)
        failure = nil
        return TerminalCommand(executable: "/bin/echo", arguments: ["샘플 모드: aws login --profile \(profile) 을(를) 실행했다고 가정합니다."])
    }

    private func simulateCall() async throws {
        if latency > .zero { try await Task.sleep(for: latency) }
        if let failure { throw failure }
    }

    private func account(for profile: String) throws -> String {
        guard let accountID = accounts[profile] else { throw AWSDiscoveryError.profileNotFound(profile) }
        return accountID
    }
}

/// 접속 요청을 기록만 한다. SSH나 터미널을 실행하지 않는다.
public actor MockConnectionService: ConnectionService {
    public private(set) var requests: [ConnectionTarget] = []
    public private(set) var terminals: [TerminalApp] = []
    private var failure: ConnectionError?

    public init() {}

    public func setFailure(_ failure: ConnectionError?) { self.failure = failure }

    public func connect(_ target: ConnectionTarget, in terminal: TerminalApp, preferNewTab: Bool) async throws -> ConnectionOutcome {
        if let failure { throw failure }
        requests.append(target)
        terminals.append(terminal)
        let destination = "\(target.profile.sshUsername)@\(target.address ?? target.instance.instanceID)"
        guard terminal.isExternal else {
            // 샘플 IP로 실제 ssh를 실행하지 않도록 안내 문구만 출력한다.
            let command = TerminalCommand(executable: "/bin/echo", arguments: ["샘플 모드: 실제로 접속하지 않습니다 (\(destination))"])
            return .embedded(EmbeddedTerminalSession(kind: .ssh(profileID: target.profile.id), title: target.profile.displayName,
                                                     destination: destination,
                                                     isProduction: target.profile.isProduction, command: command))
        }
        return .external(message: "샘플 모드: 실제로 접속하지 않았습니다 (\(destination))")
    }
}

/// 실행 요청을 기록만 한다. AppleScript를 실행하지 않는다.
public actor MockTerminalLauncher: TerminalLauncher {
    public private(set) var launched: [(command: TerminalCommand, app: TerminalApp, newTab: Bool)] = []
    private let installedApps: Set<TerminalApp>

    public init(installedApps: Set<TerminalApp> = Set(TerminalApp.allCases)) {
        self.installedApps = installedApps
    }

    public func isAvailable(_ app: TerminalApp) async -> Bool {
        installedApps.contains(app)
    }

    public func launch(_ command: TerminalCommand, in app: TerminalApp, newTab: Bool) async throws {
        guard installedApps.contains(app) else { throw TerminalLaunchError.appNotInstalled(app) }
        launched.append((command, app, newTab))
    }
}

/// 메모리에만 저장하는 동기화 Mock. iCloud에 접근하지 않는다.
public actor MockSyncService: SyncService {
    public private(set) var document: SyncedProfilesDocument?
    public private(set) var saveCount = 0
    private var conflictVersions: [SyncedProfilesDocument] = []
    private var isAvailable: Bool
    private var failure: SyncError?

    public init(document: SyncedProfilesDocument? = nil, isAvailable: Bool = true) {
        self.document = document
        self.isAvailable = isAvailable
    }

    /// 다른 Mac이 iCloud에 저장한 것처럼 문서를 바꾼다.
    public func setDocument(_ document: SyncedProfilesDocument?) { self.document = document }
    public func setConflictVersions(_ versions: [SyncedProfilesDocument]) { conflictVersions = versions }
    public func setFailure(_ failure: SyncError?) { self.failure = failure }

    public func availability() async -> SyncAvailability {
        isAvailable ? .available(location: "메모리 (샘플 모드)") : .unavailable(reason: "iCloud Drive를 사용할 수 없습니다.")
    }

    public func load() async throws -> SyncSnapshot {
        if let failure { throw failure }
        return SyncSnapshot(document: document, conflictVersions: conflictVersions)
    }

    public func save(_ document: SyncedProfilesDocument, replacing expected: SyncedProfilesDocument?,
                     resolvingConflictVersions: [SyncedProfilesDocument]) async throws {
        if let failure { throw failure }
        guard self.document == expected else { throw SyncError.remoteChanged }
        self.document = document
        conflictVersions.removeAll { resolvingConflictVersions.contains($0) }
        saveCount += 1
    }
}

/// 메모리 안의 가짜 서버 파일 시스템. 샘플 모드와 테스트에서 쓴다.
/// 내려받기는 실제로 이 Mac에 파일(내용은 안내 문구)을 만들고, 올리기는 목록에만 추가한다.
public actor MockSFTPClient: SFTPClient {
    private var directories: [String: [RemoteFileEntry]]
    private let latency: Duration
    private let home: String

    public init(home: String = "/home/ec2-user", latency: Duration = .zero, now: Date = Date()) {
        self.home = home
        self.latency = latency
        func dir(_ name: String, _ minutesAgo: Double) -> RemoteFileEntry {
            RemoteFileEntry(name: name, kind: .directory, size: 4096, modified: now.addingTimeInterval(-minutesAgo * 60),
                            permissions: "drwxr-xr-x")
        }
        func file(_ name: String, _ size: Int64, _ minutesAgo: Double) -> RemoteFileEntry {
            RemoteFileEntry(name: name, kind: .file, size: size, modified: now.addingTimeInterval(-minutesAgo * 60),
                            permissions: "-rw-r--r--")
        }
        directories = [
            "/": [dir("home", 9_000), dir("var", 9_000), dir("etc", 9_000)],
            "/home": [dir("ec2-user", 9_000)],
            home: [dir("app", 120), dir("logs", 15), file("deploy.sh", 2_150, 3_000), file(".bashrc", 231, 50_000),
                   file("release notes.txt", 18_400, 600)],
            "\(home)/app": [dir("config", 400), file("server.jar", 48_000_000, 120), file("application.yml", 3_900, 400)],
            "\(home)/app/config": [file("logback.xml", 1_200, 400)],
            "\(home)/logs": [file("app.log", 5_400_000, 1), file("app.log.1", 10_485_760, 1_440)],
            "/var": [dir("log", 100)],
            "/var/log": [file("messages", 820_000, 3)],
            "/etc": [file("hostname", 32, 90_000)],
        ]
    }

    public func homeDirectory() async throws -> String {
        try await simulate()
        return home
    }

    public func list(_ path: String) async throws -> [RemoteFileEntry] {
        try await simulate()
        let normalized = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let entries = directories[normalized] else { throw SFTPError.notFound(path) }
        return entries
    }

    public func size(of path: String) async throws -> Int64? {
        entry(at: path)?.size
    }

    public func download(_ remotePath: String, isDirectory: Bool, to localURL: URL) async throws {
        try await simulate(transfer: true)
        guard let entry = entry(at: remotePath) else { throw SFTPError.notFound(remotePath) }
        let note = Data("샘플 모드에서 만든 파일입니다: \(remotePath)\n".utf8)
        if isDirectory || entry.kind == .directory {
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            try note.write(to: localURL.appending(path: "README-sample.txt"))
        } else {
            try note.write(to: localURL)
        }
    }

    public func upload(_ localURL: URL, isDirectory: Bool, to remotePath: String) async throws {
        try await simulate(transfer: true)
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        add(RemoteFileEntry(name: (remotePath as NSString).lastPathComponent, kind: isDirectory ? .directory : .file,
                            size: isDirectory ? 4096 : size, modified: Date(),
                            permissions: isDirectory ? "drwxr-xr-x" : "-rw-r--r--"), to: RemotePath.parent(of: remotePath))
        if isDirectory, directories[remotePath] == nil { directories[remotePath] = [] }
    }

    public func makeDirectory(_ path: String) async throws {
        try await simulate()
        guard entry(at: path) == nil else { throw SFTPError.commandFailed("이미 있습니다: \(path)") }
        add(RemoteFileEntry(name: (path as NSString).lastPathComponent, kind: .directory, size: 4096, modified: Date(),
                            permissions: "drwxr-xr-x"), to: RemotePath.parent(of: path))
        directories[path] = []
    }

    private func entry(at path: String) -> RemoteFileEntry? {
        directories[RemotePath.parent(of: path)]?.first { $0.name == (path as NSString).lastPathComponent }
    }

    private func add(_ entry: RemoteFileEntry, to directory: String) {
        var entries = directories[directory] ?? []
        entries.removeAll { $0.name == entry.name }
        entries.append(entry)
        directories[directory] = entries
    }

    private func simulate(transfer: Bool = false) async throws {
        if latency > .zero { try await Task.sleep(for: transfer ? latency * 4 : latency) }
    }
}
