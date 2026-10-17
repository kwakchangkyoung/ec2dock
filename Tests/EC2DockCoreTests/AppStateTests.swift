import Foundation
import Testing
@testable import EC2DockCore

private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
@Suite("AppState")
struct AppStateTests {
    let aws = MockAWSDiscoveryService(accounts: SampleData.awsProfiles, instances: SampleData.liveInstances(now: fixedDate))
    let connection = MockConnectionService()
    let state: AppState

    init() {
        state = AppState(
            profiles: SampleData.profiles(now: fixedDate),
            cachedInstances: SampleData.cachedInstances(now: fixedDate),
            preferences: SampleData.preferences,
            aws: aws,
            connectionService: connection,
            syncService: MockSyncService(),
            now: { fixedDate }
        )
    }

    private var prodWebID: String {
        ServerProfile.makeID(accountID: SampleData.prodAccountID, region: SampleData.seoul, instanceID: SampleData.prodWebID)
    }

    private var devDBID: String {
        ServerProfile.makeID(accountID: SampleData.devAccountID, region: SampleData.seoul, instanceID: SampleData.devDBID)
    }

    private var prodAPIID: String {
        ServerProfile.makeID(accountID: SampleData.prodAccountID, region: SampleData.seoul, instanceID: SampleData.prodAPIID)
    }

    @Test func showsCacheBeforeRefresh() {
        #expect(state.items(filter: .all, query: "").count == 7)
        #expect(state.instances[prodWebID]?.publicIPAddress == "203.0.113.10")
        #expect(state.refreshStatus == .idle)
    }

    @Test func refreshUpdatesIPAndDiscoversNewInstances() async {
        await state.refresh()

        #expect(state.refreshStatus == .succeeded(fixedDate))
        #expect(state.instances[prodWebID]?.publicIPAddress == "203.0.113.25")
        let worker = state.items(filter: .all, query: "dev-worker-01")
        #expect(worker.count == 1)
        #expect(worker.first?.profile.accountAlias == "acme-dev")
        #expect(worker.first?.profile.isDevelopment == true)
        #expect(state.availableAWSProfiles == ["acme-dev", "acme-prod"])
    }

    @Test func refreshFailureKeepsCache() async {
        await aws.setFailure(.credentialsExpired(profile: "acme-prod"))
        await state.refresh()

        guard case .failed = state.refreshStatus else { Issue.record("expected failure"); return }
        #expect(state.instances[prodWebID]?.publicIPAddress == "203.0.113.10")
        #expect(state.items(filter: .all, query: "").count == 7)
    }

    @Test func toggleFavorite() {
        #expect(state.profile(id: devDBID)?.isFavorite == true)
        state.toggleFavorite(id: devDBID)
        #expect(state.profile(id: devDBID)?.isFavorite == false)
        #expect(state.items(filter: .favorites, query: "").map(\.profile.displayName) == ["prod-web-01"])
    }

    @Test func deleteProfileRemovesProfileAndCleansUpBastionReferences() {
        #expect(state.profile(id: prodAPIID) != nil)
        let bastionID = state.profile(id: prodAPIID)?.bastionProfileID
        #expect(bastionID == SampleData.prodBastionProfileID)

        // Bastion 서버를 삭제하면 이를 참조하던 서버의 bastionProfileID가 nil로 정리되어야 한다
        state.deleteProfile(id: bastionID!)
        #expect(state.profile(id: bastionID!) == nil)
        #expect(state.profile(id: prodAPIID)?.bastionProfileID == nil)

        // 대상 서버도 삭제
        state.deleteProfile(id: prodAPIID)
        #expect(state.profile(id: prodAPIID) == nil)
        #expect(state.instances[prodAPIID] == nil)
    }

    /// 설계 변경(7.4): Connect는 AWS를 호출하지 않고 캐시된 IP로 접속한다.
    @Test func prepareConnectionUsesCachedIPWithoutCallingAWS() async throws {
        await aws.setFailure(.credentialsExpired(profile: "acme-prod"))   // 로그인 만료여도 접속 준비는 된다
        let target = try state.prepareConnection(for: prodWebID)
        #expect(target.address == "203.0.113.10")
    }

    @Test func noCacheMeansRefreshFirst() {
        let state = AppState(profiles: SampleData.profiles(now: fixedDate), cachedInstances: [],
                             preferences: SampleData.preferences, aws: aws, connectionService: connection,
                             syncService: MockSyncService(), now: { fixedDate })
        #expect(throws: ConnectionError.noCachedInstance) { try state.prepareConnection(for: prodWebID) }
    }

    /// 버튼으로 재조회하면 바뀐 IP가 캐시에 반영되고 이후 접속에 쓰인다 (시나리오 A).
    @Test func refreshInstanceUpdatesCachedIP() async throws {
        let fresh = try await state.refreshInstance(id: prodWebID)
        #expect(fresh?.publicIPAddress == "203.0.113.25")
        #expect(try state.prepareConnection(for: prodWebID).address == "203.0.113.25")
    }

    @Test func refreshInstanceFailureKeepsCache() async {
        await aws.setFailure(.timeout)
        await #expect(throws: ConnectionError.discoveryFailed(.timeout)) {
            try await state.refreshInstance(id: prodWebID)
        }
        #expect(state.instances[prodWebID]?.publicIPAddress == "203.0.113.10")
    }

    @Test func refreshInstanceDetectsAccountMismatch() async {
        var settings = state.localSettings(for: prodWebID)
        settings.awsCLIProfileName = "acme-dev"
        let profile = state.profile(id: prodWebID)!
        #expect(state.updateConnectionSettings(profile: profile, settings: settings).isEmpty)

        await #expect(throws: ConnectionError.accountMismatch(expected: SampleData.prodAccountID, actual: SampleData.devAccountID)) {
            try await state.refreshInstance(id: prodWebID)
        }
        #expect(state.instances[prodWebID]?.publicIPAddress == "203.0.113.10")
    }

    /// 조회 전에는 dev 계정 매핑을 모르므로 기본 프로필(prod 계정)로 확인되고, 불일치로 차단된다.
    @Test func unmappedAccountIsBlockedBeforeRefresh() async {
        await #expect(throws: ConnectionError.accountMismatch(expected: SampleData.devAccountID, actual: SampleData.prodAccountID)) {
            try await state.refreshInstance(id: devDBID)
        }
    }

    @Test func refreshInstanceRemovesVanishedInstanceFromCache() async throws {
        await aws.setInstances([])
        #expect(try await state.refreshInstance(id: prodWebID) == nil)
        #expect(state.instances[prodWebID] == nil)
        #expect(throws: ConnectionError.noCachedInstance) { try state.prepareConnection(for: prodWebID) }
    }

    @Test func prepareConnectionFailsForTerminatedInstance() {
        let legacyID = ServerProfile.makeID(accountID: SampleData.devAccountID, region: SampleData.virginia,
                                            instanceID: SampleData.devLegacyID)
        #expect(throws: ConnectionError.instanceNotRunning(state: "terminated")) {
            try state.prepareConnection(for: legacyID)
        }
    }

    /// Production 확인은 UI를 거치지 않아도 우회할 수 없다 (설계서 12.3).
    @Test func productionConnectionRequiresConfirmation() async throws {
        let target = try state.prepareConnection(for: prodWebID)
        #expect(state.requiresProductionConfirmation(for: target.profile))

        await #expect(throws: ConnectionError.productionConfirmationRequired) {
            try await state.connect(target, productionConfirmed: false)
        }
        #expect(await connection.requests.isEmpty)

        try await state.connect(target, productionConfirmed: true)
        #expect(await connection.requests == [target])
    }

    @Test func developmentConnectionNeedsNoConfirmation() async throws {
        await state.refresh()
        let target = try state.prepareConnection(for: devDBID)
        try await state.connect(target, productionConfirmed: false)
        #expect(await connection.requests.count == 1)
    }

    @Test func invalidSettingsAreRejectedAndNotSaved() {
        var profile = state.profile(id: devDBID)!
        profile.sshUsername = "root;id"
        profile.sshPort = 0
        var settings = state.localSettings(for: devDBID)
        settings.sshKeyPath = "relative.pem"

        let issues = state.updateConnectionSettings(profile: profile, settings: settings)
        #expect(Set(issues.map(\.field)) == [.sshUsername, .sshPort, .sshKeyPath])
        #expect(state.profile(id: devDBID)?.sshUsername == "ubuntu")
        #expect(state.localSettings(for: devDBID).sshKeyPath == nil)
    }

    @Test func identifierFieldsCannotBeChanged() {
        var profile = state.profile(id: devDBID)!
        profile.instanceID = "i-0fffffffffffffff0"
        let issues = state.updateConnectionSettings(profile: profile, settings: state.localSettings(for: devDBID))
        #expect(!issues.isEmpty)
    }

    @Test func accountsSummary() {
        #expect(state.accounts.map(\.alias) == ["acme-dev", "acme-prod"])
        #expect(state.accounts.map(\.serverCount) == [3, 4])
    }
}

/// 테스트용 메모리 저장소
final class InMemoryStore: LocalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [LocalStoreFile: Data] = [:]

    func load<T: Decodable>(_ type: T.Type, from file: LocalStoreFile) throws -> T? {
        guard let data = lock.withLock({ files[file] }) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T, to file: LocalStoreFile) throws {
        let data = try JSONEncoder().encode(value)
        lock.withLock { files[file] = data }
    }

    func has(_ file: LocalStoreFile) -> Bool { lock.withLock { files[file] != nil } }
}

@MainActor
@Suite("AppState refresh & persistence")
struct AppStatePersistenceTests {
    let aws = MockAWSDiscoveryService(accounts: SampleData.awsProfiles, instances: SampleData.liveInstances(now: fixedDate))
    let store = InMemoryStore()

    private func makeState(preferences: AppPreferences = SampleData.preferences) -> AppState {
        try? store.save(preferences, to: .preferences)
        return AppState.live(store: store, aws: aws, connectionService: MockConnectionService(), syncService: MockSyncService())
    }

    @Test func firstLaunchStartsEmptyThenDiscovers() async {
        let state = makeState()
        #expect(state.profiles.isEmpty)

        await state.refresh()
        #expect(state.refreshStatus == .succeeded(state.lastRefreshDateForTesting))
        #expect(state.profiles.count == 8)
        #expect(state.profiles.allSatisfy { $0.accountAlias == "acme-dev" || $0.accountAlias == "acme-prod" })
    }

    @Test func refreshPersistsAndRelaunchShowsCache() async {
        let state = makeState()
        await state.refresh()
        state.toggleFavorite(id: state.profiles[0].id)
        #expect(store.has(.profiles))
        #expect(store.has(.instanceCache))

        let relaunched = makeState()
        #expect(relaunched.profiles.count == 8)
        #expect(relaunched.instances.count == 8)
        #expect(relaunched.profiles.filter(\.isFavorite).count == 1)
    }

    @Test func preferenceChangesArePersisted() throws {
        let state = makeState()
        state.preferences.regions.append("eu-west-1")
        let saved = try store.load(AppPreferences.self, from: .preferences)
        #expect(saved?.regions.contains("eu-west-1") == true)
    }

    @Test func onlySelectedProfilesAreScanned() async {
        var preferences = SampleData.preferences
        preferences.enabledAWSProfiles = ["acme-dev"]
        let state = makeState(preferences: preferences)
        await state.refresh()
        #expect(Set(state.profiles.map(\.accountID)) == [SampleData.devAccountID])
    }

    @Test func missingProfileIsReportedWhileOthersSucceed() async {
        var preferences = SampleData.preferences
        preferences.enabledAWSProfiles = ["acme-dev", "gone"]
        let state = makeState(preferences: preferences)
        await state.refresh()

        guard case .failed(let failures) = state.refreshStatus else {
            Issue.record("expected failure")
            return
        }
        #expect(failures.map(\.source) == ["gone"])
        #expect(!state.profiles.isEmpty)
    }

    @Test func terminatedAndRemovedInstanceLeavesCacheButKeepsProfile() async {
        let state = makeState()
        await state.refresh()
        let workerID = ServerProfile.makeID(accountID: SampleData.devAccountID, region: SampleData.seoul, instanceID: SampleData.devWorkerID)
        #expect(state.instances[workerID] != nil)

        await aws.setInstances(SampleData.liveInstances(now: fixedDate).filter { $0.instanceID != SampleData.devWorkerID })
        await state.refresh()

        #expect(state.instances[workerID] == nil)
        #expect(state.profile(id: workerID) != nil)
        #expect(state.item(id: workerID)?.stateLabel == "unknown")
    }
}

extension AppState {
    var lastRefreshDateForTesting: Date {
        if case .succeeded(let date) = refreshStatus { return date }
        return .distantPast
    }
}

@MainActor
@Suite("AppState terminal selection")
struct AppStateTerminalTests {
    @Test func usesPerServerTerminalUnlessOverridden() async throws {
        let connection = MockConnectionService()
        let state = AppState(
            profiles: SampleData.profiles(now: fixedDate),
            cachedInstances: SampleData.cachedInstances(now: fixedDate),
            preferences: SampleData.preferences,
            aws: MockAWSDiscoveryService(accounts: SampleData.awsProfiles, instances: SampleData.liveInstances(now: fixedDate)),
            connectionService: connection,
            syncService: MockSyncService(),
            now: { fixedDate }
        )
        let id = ServerProfile.makeID(accountID: SampleData.prodAccountID, region: SampleData.seoul, instanceID: SampleData.prodWebID)
        let target = try state.prepareConnection(for: id)

        try await state.connect(target, productionConfirmed: true)
        try await state.connect(target, productionConfirmed: true, terminal: .terminal)
        #expect(await connection.terminals == [.iTerm2, .terminal])
        #expect(try state.commandLine(for: target).hasSuffix("-- ec2-user@203.0.113.10"))
    }
}

@MainActor
@Suite("AppState embedded sessions")
struct AppStateEmbeddedSessionTests {
    @Test func embeddedSessionKeepsProductionCheck() async throws {
        let state = AppState(
            profiles: SampleData.profiles(now: fixedDate),
            cachedInstances: SampleData.cachedInstances(now: fixedDate),
            preferences: SampleData.preferences,
            aws: MockAWSDiscoveryService(accounts: SampleData.awsProfiles, instances: SampleData.liveInstances(now: fixedDate)),
            connectionService: MockConnectionService(),
            syncService: MockSyncService(),
            now: { fixedDate }
        )
        let id = ServerProfile.makeID(accountID: SampleData.prodAccountID, region: SampleData.seoul, instanceID: SampleData.prodWebID)
        let target = try state.prepareConnection(for: id)

        await #expect(throws: ConnectionError.productionConfirmationRequired) {
            try await state.connect(target, productionConfirmed: false, terminal: .embedded)
        }

        let outcome = try await state.connect(target, productionConfirmed: true, terminal: .embedded)
        guard case .embedded(let session) = outcome else {
            Issue.record("expected embedded outcome")
            return
        }
        #expect(session.profileID == id)
        #expect(session.isProduction)
    }
}

@MainActor
@Suite("AppState bastion")
struct AppStateBastionTests {
    let state = AppState(
        profiles: SampleData.profiles(now: fixedDate),
        cachedInstances: SampleData.cachedInstances(now: fixedDate),
        preferences: SampleData.preferences,
        aws: MockAWSDiscoveryService(accounts: SampleData.awsProfiles, instances: SampleData.liveInstances(now: fixedDate)),
        connectionService: MockConnectionService(),
        syncService: MockSyncService(),
        now: { fixedDate }
    )

    private var apiID: String { ServerProfile.makeID(accountID: SampleData.prodAccountID, region: SampleData.seoul, instanceID: SampleData.prodAPIID) }
    private var webID: String { ServerProfile.makeID(accountID: SampleData.prodAccountID, region: SampleData.seoul, instanceID: SampleData.prodWebID) }

    /// 샘플의 prod-api-01은 prod-bastion을 경유한다.
    @Test func sampleBastionServerIsConnectable() throws {
        let target = try state.prepareConnection(for: apiID)
        #expect(target.address == "10.0.12.34")
        #expect(target.bastion?.profile.displayName == "prod-bastion")
        #expect(target.bastion?.address == "203.0.113.5")
        #expect(state.connectionBlockingReason(for: apiID) == nil)
    }

    /// 같은 계정·같은 VPC에서 공인 IP가 있는 서버만 후보가 된다.
    @Test func candidatesAreFilteredBySameVPCAndPublicIP() {
        let api = state.profile(id: apiID)!
        let names = Set(state.bastionCandidates(for: api).map(\.displayName))
        // prod-batch-01(다른 리전 VPC, 공인 IP 없음)과 dev 계정 서버는 제외된다.
        #expect(names == ["prod-web-01", "prod-bastion"])
    }

    @Test func currentBastionStaysInCandidatesEvenIfUnqualified() {
        var api = state.profile(id: apiID)!
        let batchID = ServerProfile.makeID(accountID: SampleData.prodAccountID, region: SampleData.virginia, instanceID: SampleData.prodBatchID)
        api.bastionProfileID = batchID
        #expect(state.bastionCandidates(for: api).contains { $0.id == batchID })
    }

    @Test func bastionWithoutPublicIPBlocksConnect() {
        var api = state.profile(id: apiID)!
        let batchID = ServerProfile.makeID(accountID: SampleData.prodAccountID, region: SampleData.virginia, instanceID: SampleData.prodBatchID)
        api.bastionProfileID = batchID
        #expect(state.updateConnectionSettings(profile: api, settings: state.localSettings(for: apiID)).isEmpty)
        #expect(state.connectionBlockingReason(for: apiID) == .bastionNoPublicIP)
        #expect(state.connectionBlockingReason(for: webID) == nil)
    }
}
