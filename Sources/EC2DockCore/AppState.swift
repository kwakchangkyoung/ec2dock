import Foundation
import Observation

public struct RefreshFailure: Identifiable, Equatable, Sendable {
    /// 실패한 대상 (예: "acme-prod · ap-northeast-2")
    public let source: String
    public let message: String
    public let suggestion: String?
    /// 로그인하면 해결되는 실패라면 해당 AWS CLI 프로필
    public let loginProfile: String?

    public var id: String { "\(source)|\(message)" }

    init(source: String, error: any Error) {
        self.source = source
        let localized = error as? LocalizedError
        self.message = localized?.errorDescription ?? "알 수 없는 오류가 발생했습니다."
        self.suggestion = localized?.recoverySuggestion
        self.loginProfile = (error as? AWSDiscoveryError)?.loginProfile
    }
}

/// 새로고침 진행 상황 (계정 × 리전 조회 수)
public struct RefreshProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
}

public enum RefreshStatus: Equatable, Sendable {
    case idle
    case refreshing
    case succeeded(Date)
    /// 일부 또는 전체 조회 실패. 성공한 대상의 결과는 반영되고 나머지는 캐시를 유지한다.
    case failed([RefreshFailure])
}

/// UI가 관찰하는 앱 상태. 서비스는 프로토콜로 주입받는다.
@MainActor
@Observable
public final class AppState {
    public private(set) var profiles: [ServerProfile]
    public private(set) var instances: [String: EC2Instance]
    public private(set) var localSettings: [String: LocalConnectionSettings]
    public var preferences: AppPreferences {
        didSet {
            guard preferences != oldValue else { return }
            persist(preferences, to: .preferences)
        }
    }
    public private(set) var availableAWSProfiles: [String] = []
    public private(set) var refreshStatus: RefreshStatus = .idle
    /// 이 Mac에서 AWS CLI를 찾지 못했는지 (시작 체크리스트에 표시)
    public private(set) var isAWSCLIMissing = false
    /// 계정 확인이 끝나 리전 조회를 시작하면 채워진다.
    public private(set) var refreshProgress: RefreshProgress?
    public private(set) var syncStatus: SyncStatus = .disabled
    public private(set) var syncAvailability: SyncAvailability?
    public private(set) var syncConflicts: [SyncConflict] = []
    /// 마지막으로 iCloud와 맞춘 프로필 (3-way 병합 기준)
    private var syncBase: [ServerProfile] = []
    private var syncVersionResolutions: [ServerProfile] = []
    private var syncConflictDocument: SyncedProfilesDocument?
    private var isSyncing = false
    /// 로컬 파일 저장/읽기 실패 메시지
    public var persistenceError: String? {
        let messages = LocalStoreFile.allCases.compactMap { persistenceErrors[$0] }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    private var persistenceErrors: [LocalStoreFile: String] = [:]

    /// 조회로 확인한 계정 ID → AWS CLI 프로필
    private var accountProfiles: [String: String] = [:]

    private let aws: any AWSDiscoveryService
    private let connectionService: any ConnectionService
    private let syncService: any SyncService
    private let store: (any LocalStore)?
    private let now: @Sendable () -> Date

    public init(
        profiles: [ServerProfile],
        cachedInstances: [EC2Instance],
        localSettings: [LocalConnectionSettings] = [],
        preferences: AppPreferences,
        aws: any AWSDiscoveryService,
        connectionService: any ConnectionService,
        syncService: any SyncService,
        store: (any LocalStore)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profiles = profiles
        self.instances = Dictionary(cachedInstances.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        self.localSettings = Dictionary(localSettings.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        self.preferences = preferences
        self.aws = aws
        self.connectionService = connectionService
        self.syncService = syncService
        self.store = store
        self.now = now
    }

    /// 실제 AWS CLI로 조회하고, 실제 터미널에서 SSH로 접속하며, iCloud Drive로 동기화하는 상태.
    public static func live(
        store: any LocalStore,
        aws: any AWSDiscoveryService = AWSCLIDiscoveryService(),
        connectionService: any ConnectionService = TerminalConnectionService(),
        syncService: any SyncService = ICloudDriveSyncService()
    ) -> AppState {
        var loadErrors: [LocalStoreFile: String] = [:]
        func load<T: Decodable>(_ type: T.Type, _ file: LocalStoreFile) -> T? {
            do {
                return try store.load(type, from: file)
            } catch {
                loadErrors[file] = "\(file.rawValue) 읽기에 실패해 기본값으로 시작했습니다."
                return nil
            }
        }

        let state = AppState(
            profiles: load([ServerProfile].self, .profiles) ?? [],
            cachedInstances: load([EC2Instance].self, .instanceCache) ?? [],
            localSettings: load([LocalConnectionSettings].self, .localSettings) ?? [],
            preferences: load(AppPreferences.self, .preferences) ?? AppPreferences(),
            aws: aws,
            connectionService: connectionService,
            syncService: syncService,
            store: store
        )
        state.syncBase = load([ServerProfile].self, .syncBase) ?? []
        state.syncVersionResolutions = load([ServerProfile].self, .syncVersionResolutions) ?? []
        state.accountProfiles = load([String: String].self, .accountProfiles) ?? [:]
        state.persistenceErrors = loadErrors
        return state
    }

    /// 샘플 데이터와 Mock 서비스로 구성한 상태 (Phase 1 기본값)
    public static func sample() -> AppState {
        AppState(
            profiles: SampleData.profiles(),
            cachedInstances: SampleData.cachedInstances(),
            preferences: SampleData.preferences,
            aws: MockAWSDiscoveryService(
                accounts: SampleData.awsProfiles,
                instances: SampleData.liveInstances(),
                latency: .milliseconds(600)
            ),
            connectionService: MockConnectionService(),
            syncService: MockSyncService()
        )
    }

    // MARK: - 조회

    public var isRefreshing: Bool { refreshStatus == .refreshing }

    /// 캐시에 있는 데이터 중 가장 최근 조회 시각
    public var lastFetchedAt: Date? { instances.values.map(\.lastFetchedAt).max() }

    public func items(
        filter: ServerFilter,
        query: String,
        scope: SearchScope = .all,
        state: InstanceStateFilter = .all
    ) -> [ServerListItem] {
        ServerSearch.filter(profiles.map { ServerListItem(profile: $0, instance: instances[$0.id]) },
                            by: filter, query: query, scope: scope, state: state)
    }

    public func item(id: String) -> ServerListItem? {
        profile(id: id).map { ServerListItem(profile: $0, instance: instances[$0.id]) }
    }

    public func profile(id: String) -> ServerProfile? {
        profiles.first { $0.id == id }
    }

    /// 화면에 보여줄 계정 이름: 이 Mac에서 그 계정을 조회하는 AWS CLI 프로필 이름.
    /// 모르면 서버 프로필에 저장된 별칭(처음 발견할 때의 프로필 이름, iCloud 동기화 값)을 쓴다.
    /// 저장된 별칭은 바꾸지 않는다 — Mac마다 프로필 이름이 달라 동기화 충돌이 생길 수 있다.
    public func accountLabel(for accountID: String) -> String {
        if let awsProfile = accountProfiles[accountID] { return awsProfile }
        return profiles.first { $0.accountID == accountID }?.accountAlias ?? accountID
    }

    /// 사이드바 "AWS Accounts": 서버가 있는 계정 + 서버가 아직 없는 조회 대상 프로필.
    public var accounts: [AccountSummary] {
        let scanned = Set(preferences.profilesToScan)
        var result = Dictionary(grouping: profiles, by: \.accountID).map { accountID, servers in
            let awsProfile = accountProfiles[accountID]
            return AccountSummary(accountID: accountID, alias: accountLabel(for: accountID), serverCount: servers.count,
                                  awsProfile: awsProfile, isScanned: awsProfile.map(scanned.contains) ?? false)
        }
        let shownProfiles = Set(result.compactMap(\.awsProfile) + result.map(\.alias))
        for awsProfile in preferences.profilesToScan
        where availableAWSProfiles.contains(awsProfile) && !shownProfiles.contains(awsProfile) {
            if let accountID = accountProfiles.first(where: { $0.value == awsProfile })?.key {
                // 조회는 했지만 조회 리전에 서버가 없는 계정
                result.append(AccountSummary(accountID: accountID, alias: awsProfile, serverCount: 0, awsProfile: awsProfile))
            } else {
                result.append(AccountSummary(accountID: "profile:\(awsProfile)", alias: awsProfile, serverCount: 0,
                                             awsProfile: awsProfile, isPending: true))
            }
        }
        return result.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    /// Bastion 후보: 같은 계정의 다른 서버 중 공인 IP가 있는 서버.
    /// 두 서버의 VPC를 알면 같은 VPC로 좁힌다. 현재 지정된 Bastion은 조건과 관계없이 남긴다.
    public func bastionCandidates(for profile: ServerProfile) -> [ServerProfile] {
        let targetVPC = instances[profile.id]?.vpcID
        return profiles.filter { candidate in
            guard candidate.accountID == profile.accountID, candidate.id != profile.id else { return false }
            if candidate.id == profile.bastionProfileID { return true }
            guard let instance = instances[candidate.id], instance.publicIPAddress != nil else { return false }
            if let targetVPC, let candidateVPC = instance.vpcID { return targetVPC == candidateVPC }
            return true
        }
    }

    /// 설계서 7.1 조회 흐름: 프로필 → 계정 확인 → 리전 순회 → 인스턴스 병합.
    /// 선택한 프로필만 조회하며, 실패한 대상은 기존 캐시를 유지한다.
    public func refresh() async {
        guard !isRefreshing else { return }
        refreshStatus = .refreshing
        refreshProgress = nil
        defer { refreshProgress = nil }

        do {
            availableAWSProfiles = try await aws.listProfiles()
        } catch is CancellationError {
            refreshStatus = .idle
            return
        } catch {
            refreshStatus = .failed([RefreshFailure(source: "AWS CLI", error: error)])
            return
        }

        var failures: [RefreshFailure] = []
        var validProfiles: [(profile: String, accountID: String)] = []

        for awsProfile in preferences.profilesToScan {
            guard availableAWSProfiles.contains(awsProfile) else {
                failures.append(RefreshFailure(source: awsProfile, error: AWSDiscoveryError.profileNotFound(awsProfile)))
                continue
            }
            let identity: AWSCallerIdentity
            do {
                identity = try await aws.callerIdentity(profile: awsProfile)
            } catch is CancellationError {
                refreshStatus = .idle
                return
            } catch {
                failures.append(RefreshFailure(source: awsProfile, error: error))
                continue
            }
            accountProfiles[identity.accountID] = awsProfile
            validProfiles.append((profile: awsProfile, accountID: identity.accountID))
        }

        let regions = preferences.regions
        let awsService = aws

        struct RegionFetchResult: Sendable {
            let order: Int
            let awsProfile: String
            let accountID: String
            let region: String
            let instances: [EC2Instance]?
            let error: (any Error)?
        }

        var tasks: [(order: Int, profile: String, accountID: String, region: String)] = []
        var orderIndex = 0
        for item in validProfiles {
            for region in regions {
                tasks.append((order: orderIndex, profile: item.profile, accountID: item.accountID, region: region))
                orderIndex += 1
            }
        }

        refreshProgress = RefreshProgress(completed: 0, total: tasks.count)
        let results: [RegionFetchResult] = await withTaskGroup(of: RegionFetchResult.self) { group in
            for task in tasks {
                group.addTask {
                    do {
                        let found = try await awsService.describeInstances(profile: task.profile, region: task.region)
                        return RegionFetchResult(order: task.order, awsProfile: task.profile, accountID: task.accountID, region: task.region, instances: found, error: nil)
                    } catch {
                        return RegionFetchResult(order: task.order, awsProfile: task.profile, accountID: task.accountID, region: task.region, instances: nil, error: error)
                    }
                }
            }
            var collected: [RegionFetchResult] = []
            for await res in group {
                collected.append(res)
                refreshProgress = RefreshProgress(completed: collected.count, total: tasks.count)
            }
            return collected.sorted { $0.order < $1.order }
        }

        if Task.isCancelled {
            refreshStatus = .idle
            return
        }

        for result in results {
            if let error = result.error {
                if error is CancellationError {
                    refreshStatus = .idle
                    return
                }
                failures.append(RefreshFailure(source: "\(result.awsProfile) · \(result.region)", error: error))
            } else if let found = result.instances {
                merge(found, accountID: result.accountID, region: result.region, defaultAlias: result.awsProfile)
            }
        }

        persist(profiles, to: .profiles)
        persist(Array(instances.values), to: .instanceCache)
        persist(accountProfiles, to: .accountProfiles)
        refreshStatus = failures.isEmpty ? .succeeded(now()) : .failed(failures)
    }

    /// AWS CLI 로그인을 내장 터미널에서 실행할 세션.
    /// SSO 프로필이면 `aws sso login`, 그 외에는 `aws login`을 쓴다.
    public func loginSession(for awsProfile: String) async throws -> EmbeddedTerminalSession {
        let command = try await aws.loginCommand(profile: awsProfile)
        return EmbeddedTerminalSession(kind: .awsLogin(awsProfile: awsProfile), title: "AWS 로그인 · \(awsProfile)",
                                       destination: command.arguments.prefix(2).joined(separator: " "),
                                       isProduction: false, command: command)
    }

    /// 해당 프로필로 AWS 계정 확인(`sts get-caller-identity`)이 되는지. 로그인 완료 확인에 쓴다.
    public func isLoggedIn(awsProfile: String) async -> Bool {
        (try? await aws.callerIdentity(profile: awsProfile)) != nil
    }

    /// 새 AWS 계정(프로필)을 추가하는 대화형 세션. 성공하면 `completeAccountAddition`을 호출한다.
    public func addAccountSession(profile: String, method: AWSAccountSetupMethod) async throws -> EmbeddedTerminalSession {
        let command = try await aws.addAccountCommand(profile: profile, method: method)
        return EmbeddedTerminalSession(kind: .awsLogin(awsProfile: profile), title: "AWS 계정 추가 · \(profile)",
                                       destination: (["aws"] + method.arguments).joined(separator: " "),
                                       isProduction: false, command: command)
    }

    /// 계정 추가가 끝나면 조회 대상에 넣고 새로고침한다.
    /// 조회 대상이 비어 있으면 그동안 기본 프로필만 조회하던 것이므로 기본 프로필도 함께 유지한다.
    public func completeAccountAddition(profile: String) async {
        await reloadAWSProfiles()
        var enabled = preferences.enabledAWSProfiles
        if enabled.isEmpty, availableAWSProfiles.contains(preferences.defaultAWSProfile) {
            enabled.append(preferences.defaultAWSProfile)
        }
        if !enabled.contains(profile) { enabled.append(profile) }
        preferences.enabledAWSProfiles = enabled.sorted()
        await refresh()
    }

    /// 로컬 AWS CLI 설정의 프로필 이름만 읽는다 (네트워크·자격 증명 사용 없음).
    public func reloadAWSProfiles() async {
        do {
            availableAWSProfiles = try await aws.listProfiles()
            isAWSCLIMissing = false
        } catch AWSDiscoveryError.cliNotFound {
            isAWSCLIMissing = true
        } catch {
            // 다른 오류는 새로고침 때 원인과 함께 표시한다.
        }
    }

    /// 성공적으로 조회한 계정+리전의 캐시를 결과로 교체한다.
    /// 사라진 인스턴스는 캐시에서만 지우고, 사용자 프로필은 유지한다.
    private func merge(_ found: [EC2Instance], accountID: String, region: String, defaultAlias: String) {
        let foundIDs = Set(found.map(\.id))
        instances = instances.filter { id, instance in
            instance.accountID != accountID || instance.region != region || foundIDs.contains(id)
        }
        for instance in found {
            instances[instance.id] = instance
            if profile(id: instance.id) == nil {
                let alias = profiles.first { $0.accountID == instance.accountID }?.accountAlias ?? defaultAlias
                profiles.append(.discovered(from: instance, accountAlias: alias, now: now()))
            }
        }
    }

    // MARK: - 사용자 설정

    public func toggleFavorite(id: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].isFavorite.toggle()
        profiles[index].updatedAt = now()
        persist(profiles, to: .profiles)
    }

    /// 서버 프로필을 삭제하고 관련 캐시와 설정을 정리한다.
    public func deleteProfile(id: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: index)
        instances.removeValue(forKey: id)
        localSettings.removeValue(forKey: id)

        // 다른 프로필의 Bastion 참조가 이 프로필을 가리키고 있다면 해제한다.
        for idx in profiles.indices where profiles[idx].bastionProfileID == id {
            profiles[idx].bastionProfileID = nil
            profiles[idx].updatedAt = now()
        }

        persist(profiles, to: .profiles)
        persist(Array(instances.values), to: .instanceCache)
        persist(Array(localSettings.values), to: .localSettings)
    }

    public func localSettings(for id: String) -> LocalConnectionSettings {
        if let stored = localSettings[id] { return stored }
        let accountID = profile(id: id)?.accountID ?? ""
        return LocalConnectionSettings(
            profileID: id,
            awsCLIProfileName: accountProfiles[accountID] ?? preferences.defaultAWSProfile,
            terminalIdentifier: preferences.defaultTerminal
        )
    }

    /// 검증에 실패하면 변경하지 않고 문제 목록을 반환한다.
    /// 계정/리전/인스턴스 ID는 식별자이므로 변경할 수 없다.
    @discardableResult
    public func updateConnectionSettings(profile updated: ServerProfile, settings: LocalConnectionSettings) -> [ValidationIssue] {
        guard let index = profiles.firstIndex(where: { $0.id == updated.id }), settings.profileID == updated.id else {
            return [ValidationIssue(field: .instanceID, message: "서버 식별자는 변경할 수 없습니다.")]
        }
        let issues = InputValidator.validate(updated) + InputValidator.validate(settings)
        guard issues.isEmpty else { return issues }

        var profile = updated
        profile.updatedAt = now()
        profiles[index] = profile
        localSettings[settings.id] = settings
        persist(profiles, to: .profiles)
        persist(Array(localSettings.values), to: .localSettings)
        return []
    }

    // MARK: - iCloud 동기화

    public enum SyncResolution: Sendable {
        case keepLocal
        case keepRemote
    }

    public func refreshSyncAvailability() async {
        syncAvailability = await syncService.availability()
    }

    /// 마지막 동기화 시점을 기준으로 이 Mac과 iCloud의 프로필을 병합한다 (설계서 9.3).
    /// 양쪽에서 모두 바뀐 프로필은 덮어쓰지 않고 `syncConflicts`로 남긴다.
    /// 실패해도 이 Mac의 데이터는 그대로 두고 로컬 모드로 계속 동작한다.
    public func syncNow() async {
        guard preferences.iCloudSyncEnabled else {
            syncStatus = .disabled
            syncConflicts = []
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        syncStatus = .syncing

        do {
            let snapshot = try await syncService.load()
            var conflicts: [String: SyncConflict] = [:]

            // 다른 Mac이 오프라인에서 남긴 파일 버전의 변경을 먼저 이 Mac 목록에 반영한다.
            // 기준(base)은 바꾸지 않아야 아래 병합에서 iCloud로 올라간다.
            var working = profiles
            for version in snapshot.conflictVersions {
                let resolvedProfiles = version.profiles.map { remote in
                    if syncVersionResolutions.contains(where: { $0.hasSameContent(as: remote) }),
                       let local = working.first(where: { $0.id == remote.id }) {
                        return local
                    }
                    return remote
                }
                let result = ProfileSyncMerger.merge(local: working, remote: resolvedProfiles, base: syncBase)
                working = result.local
                result.conflicts.forEach { conflicts[$0.id] = $0 }
            }

            let remoteProfiles = snapshot.document?.profiles ?? []
            let result = ProfileSyncMerger.merge(local: working, remote: remoteProfiles, base: syncBase)
            result.conflicts.forEach { conflicts[$0.id] = $0 }

            // 충돌 파일은 모든 선택이 끝날 때까지 원본과 비교 기준을 그대로 보존한다.
            if !snapshot.conflictVersions.isEmpty && !conflicts.isEmpty {
                syncConflictDocument = snapshot.document
                syncConflicts = conflicts.values.sorted { $0.id < $1.id }
                syncStatus = .conflicts(syncConflicts.count)
                return
            }
            if result.local != profiles {
                profiles = result.local
            }
            guard persist(profiles, to: .profiles) else {
                throw SyncError.fileAccess("로컬 프로필을 저장하지 못했습니다.")
            }
            if snapshot.document == nil || result.remote != remoteProfiles || !snapshot.conflictVersions.isEmpty {
                try await syncService.save(SyncedProfilesDocument(profiles: result.remote),
                                           resolvingConflictVersions: snapshot.conflictVersions)
            }
            // iCloud에 저장이 끝난 뒤에만 기준을 옮긴다. 저장에 실패하면 다음 동기화에서 다시 올린다.
            syncBase = result.base
            persist(syncBase, to: .syncBase)
            syncVersionResolutions = []
            persist(syncVersionResolutions, to: .syncVersionResolutions)

            syncConflicts = conflicts.values.sorted {
                $0.local.displayName.localizedStandardCompare($1.local.displayName) == .orderedAscending
            }
            syncConflictDocument = snapshot.document
            syncStatus = syncConflicts.isEmpty ? .synced(now()) : .conflicts(syncConflicts.count)
        } catch is CancellationError {
            syncStatus = .disabled
        } catch {
            syncStatus = .failed((error as? LocalizedError)?.errorDescription ?? "알 수 없는 오류")
        }
    }

    /// 충돌 해결: 고른 쪽을 남기고 다시 동기화한다.
    public func resolveConflict(id: String, keep resolution: SyncResolution) async {
        guard !isSyncing, let conflict = syncConflicts.first(where: { $0.id == id }) else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let snapshot = try await syncService.load()
            let previousRemote = syncConflictDocument?.profiles.first { $0.id == id }
            let currentRemote = snapshot.document?.profiles.first { $0.id == id }
            if previousRemote != currentRemote {
                isSyncing = false
                await syncNow()
                return
            }
            if snapshot.conflictVersions.contains(where: { version in
                version.profiles.contains { $0.hasSameContent(as: conflict.remote) }
            }) {
                syncVersionResolutions.append(conflict.remote)
            }
            // 충돌 버전이 아닌 현재 주 문서를 기준으로 선택한 값을 올린다.
            syncBase.removeAll { $0.id == id }
            if let remote = snapshot.document?.profiles.first(where: { $0.id == id }) {
                syncBase.append(remote)
            }

            if resolution == .keepRemote, let index = profiles.firstIndex(where: { $0.id == id }) {
                profiles[index] = conflict.remote
            }
            guard persist(profiles, to: .profiles),
                  persist(syncBase, to: .syncBase),
                  persist(syncVersionResolutions, to: .syncVersionResolutions) else {
                throw SyncError.fileAccess("충돌 해결 결과를 로컬에 저장하지 못했습니다.")
            }
            syncConflicts.removeAll { $0.id == id }
        } catch {
            syncStatus = .failed((error as? LocalizedError)?.errorDescription ?? "알 수 없는 오류")
            return
        }
        isSyncing = false
        await syncNow()
    }

    // MARK: - 접속

    /// 마지막으로 조회해 둔 캐시 정보로 접속 대상을 만든다. AWS를 호출하지 않는다.
    /// (설계 변경: 설계서 7.4의 "접속 직전 재조회"를 사용자 결정으로 "캐시 우선 + 버튼으로 재조회"로 바꿨다.
    ///  IP가 바뀌었다면 HostKeyAlias 기반 호스트 키 검증이 엉뚱한 서버 접속을 막는다.)
    public func prepareConnection(for id: String) throws(ConnectionError) -> ConnectionTarget {
        guard let profile = profile(id: id) else { throw .instanceNotFound }
        let settings = localSettings(for: id)

        let issues = InputValidator.validate(profile) + InputValidator.validate(settings)
        guard issues.isEmpty else { throw .invalidConfiguration(issues.map(\.message)) }
        guard let cached = instances[id] else { throw .noCachedInstance }

        var bastion: BastionInput?
        if profile.connectionType == .bastionSSH, let bastionID = profile.bastionProfileID,
           let bastionProfile = self.profile(id: bastionID) {
            bastion = BastionInput(profile: bastionProfile, instance: instances[bastionID],
                                   settings: localSettings(for: bastionID))
        }
        return try ConnectionPreflight.makeTarget(profile: profile, instance: cached, settings: settings, bastion: bastion)
    }

    /// Connect 버튼을 비활성화할 사유. 실제 접속 준비와 같은 검증을 쓴다.
    public func connectionBlockingReason(for id: String) -> ConnectionError? {
        do {
            _ = try prepareConnection(for: id)
            return nil
        } catch {
            return error
        }
    }

    /// 버튼으로 요청한 서버 한 대 재조회: 계정 확인 후 최신 상태와 IP로 캐시를 갱신한다.
    /// 인스턴스가 더 이상 없으면 캐시에서 지운다.
    @discardableResult
    public func refreshInstance(id: String) async throws(ConnectionError) -> EC2Instance? {
        guard let profile = profile(id: id) else { throw .instanceNotFound }
        let settings = localSettings(for: id)
        guard InputValidator.isValidAWSProfileName(settings.awsCLIProfileName) else {
            throw .invalidConfiguration(["AWS CLI 프로필 이름 형식이 올바르지 않습니다."])
        }

        let fresh: EC2Instance?
        do {
            let identity = try await aws.callerIdentity(profile: settings.awsCLIProfileName)
            guard identity.accountID == profile.accountID else {
                throw ConnectionError.accountMismatch(expected: profile.accountID, actual: identity.accountID)
            }
            fresh = try await aws.describeInstance(
                profile: settings.awsCLIProfileName, region: profile.region, instanceID: profile.instanceID)
        } catch let error as ConnectionError {
            throw error
        } catch let error as AWSDiscoveryError {
            throw .discoveryFailed(error)
        } catch {
            throw .discoveryFailed(.invalidResponse)
        }

        instances[id] = fresh
        persist(Array(instances.values), to: .instanceCache)
        return fresh
    }

    public func requiresProductionConfirmation(for profile: ServerProfile) -> Bool {
        preferences.confirmProductionConnections && profile.isProduction
    }

    /// Production 확인 정책은 UI가 아닌 이 계층에서 강제한다 (우회 방지).
    /// `terminal`을 지정하지 않으면 서버별 로컬 설정의 터미널을 사용한다.
    @discardableResult
    public func connect(_ target: ConnectionTarget, productionConfirmed: Bool, terminal: TerminalApp? = nil) async throws -> ConnectionOutcome {
        if requiresProductionConfirmation(for: target.profile) && !productionConfirmed {
            throw ConnectionError.productionConfirmationRequired
        }
        let app = terminal ?? TerminalApp(rawValue: target.settings.terminalIdentifier) ?? .iTerm2
        return try await connectionService.connect(target, in: app, preferNewTab: preferences.iTermOpensNewTab)
    }

    /// 터미널 실행이 실패했을 때 직접 붙여 넣을 수 있는 명령 (FR-015).
    public func commandLine(for target: ConnectionTarget) throws -> String {
        try SSHCommandBuilder().command(for: target).shellCommandLine
    }

    @discardableResult
    private func persist<T: Encodable>(_ value: T, to file: LocalStoreFile) -> Bool {
        guard let store else { return true }
        do {
            try store.save(value, to: file)
            persistenceErrors[file] = nil
            return true
        } catch {
            persistenceErrors[file] = "\(file.rawValue) 저장에 실패했습니다."
            return false
        }
    }
}
