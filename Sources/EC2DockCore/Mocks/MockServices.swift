import Foundation

/// 실제 AWS 계정 없이 동작하는 조회 Mock. AWS CLI를 실행하지 않는다.
public actor MockAWSDiscoveryService: AWSDiscoveryService {
    /// AWS CLI 프로필 이름 → 계정 ID
    private var accounts: [String: String]
    private var instances: [EC2Instance]
    private var failure: AWSDiscoveryError?
    private let latency: Duration

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

    public func save(_ document: SyncedProfilesDocument,
                     resolvingConflictVersions: [SyncedProfilesDocument]) async throws {
        if let failure { throw failure }
        self.document = document
        conflictVersions.removeAll { resolvingConflictVersions.contains($0) }
        saveCount += 1
    }
}
