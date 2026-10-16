import Foundation
import Testing
@testable import EC2DockCore

private let created = Date(timeIntervalSince1970: 1_800_000_000)
private let edited = created.addingTimeInterval(3_600)

private func profile(_ instanceID: String = "i-0123456789abcdef0", name: String = "web", edit: (inout ServerProfile) -> Void = { _ in }) -> ServerProfile {
    var profile = ServerProfile(accountID: "111111111111", accountAlias: "acme", region: "ap-northeast-2",
                                instanceID: instanceID, displayName: name, createdAt: created, updatedAt: created)
    edit(&profile)
    return profile
}

private func edited(_ base: ServerProfile, _ change: (inout ServerProfile) -> Void) -> ServerProfile {
    var profile = base
    change(&profile)
    profile.updatedAt = edited
    return profile
}

@Suite("ProfileSyncMerger")
struct ProfileSyncMergerTests {
    @Test func unchangedOnBothSidesIsNoop() {
        let p = profile()
        let result = ProfileSyncMerger.merge(local: [p], remote: [p], base: [p])
        #expect(result.local == [p])
        #expect(result.remote == [p])
        #expect(result.conflicts.isEmpty)
    }

    @Test func localChangeIsPushed() {
        let base = profile()
        let local = edited(base) { $0.isFavorite = true }
        let result = ProfileSyncMerger.merge(local: [local], remote: [base], base: [base])
        #expect(result.remote == [local])
        #expect(result.base == [local])
        #expect(result.conflicts.isEmpty)
    }

    @Test func remoteChangeIsPulled() {
        let base = profile()
        let remote = edited(base) { $0.groupName = "api" }
        let result = ProfileSyncMerger.merge(local: [base], remote: [remote], base: [base])
        #expect(result.local == [remote])
        #expect(result.conflicts.isEmpty)
    }

    /// 양쪽이 서로 다르게 바뀌면 조용히 덮어쓰지 않는다 (설계서 9.3).
    @Test func concurrentEditsBecomeConflict() {
        let base = profile()
        let local = edited(base) { $0.sshUsername = "ubuntu" }
        var remote = edited(base) { $0.sshUsername = "admin" }
        remote.updatedAt = edited.addingTimeInterval(60)   // 더 최신이어도 덮어쓰지 않는다

        let result = ProfileSyncMerger.merge(local: [local], remote: [remote], base: [base])

        #expect(result.local == [local])
        #expect(result.remote == [remote])
        #expect(result.base == [base])
        #expect(result.conflicts == [SyncConflict(local: local, remote: remote)])
        #expect(result.conflicts.first?.differences.map(\.label) == ["SSH 사용자"])
    }

    @Test func sameChangeOnBothSidesIsNotConflict() {
        let base = profile()
        let local = edited(base) { $0.isFavorite = true }
        var remote = local
        remote.updatedAt = edited.addingTimeInterval(30)
        #expect(ProfileSyncMerger.merge(local: [local], remote: [remote], base: [base]).conflicts.isEmpty)
    }

    @Test func profilesOnOneSideAreAddedToTheOther() {
        let a = profile("i-0aaaaaaaaaaaaaaa1", name: "a")
        let b = profile("i-0bbbbbbbbbbbbbbb2", name: "b")
        let result = ProfileSyncMerger.merge(local: [a], remote: [b], base: [])
        #expect(Set(result.local.map(\.id)) == [a.id, b.id])
        #expect(Set(result.remote.map(\.id)) == [a.id, b.id])
    }

    /// 두 번째 Mac의 첫 동기화: 자동 발견된 그대로인 프로필은 다른 Mac에서 수정한 값으로 바뀐다.
    @Test func firstSyncPrefersEditedOverPristine() {
        let pristine = profile()
        let customized = edited(pristine) { $0.displayName = "웹 서버"; $0.isFavorite = true }
        let result = ProfileSyncMerger.merge(local: [pristine], remote: [customized], base: [])
        #expect(result.local == [customized])
        #expect(result.conflicts.isEmpty)
    }

    @Test func firstSyncWithEditsOnBothSidesIsConflict() {
        let pristine = profile()
        let local = edited(pristine) { $0.groupName = "a" }
        let remote = edited(pristine) { $0.groupName = "b" }
        #expect(ProfileSyncMerger.merge(local: [local], remote: [remote], base: []).conflicts.count == 1)
    }

    @Test func timestampOnlyDifferenceIsIgnored() {
        let p = profile()
        var touched = p
        touched.updatedAt = edited
        #expect(p.hasSameContent(as: touched))
    }
}

@MainActor
@Suite("AppState iCloud sync")
struct AppStateSyncTests {
    let aws = MockAWSDiscoveryService(accounts: SampleData.awsProfiles, instances: [])

    private func makeMac(sync: MockSyncService, profiles: [ServerProfile], enabled: Bool = true) -> AppState {
        let store = InMemoryStore()
        try? store.save(profiles, to: .profiles)
        var preferences = AppPreferences()
        preferences.iCloudSyncEnabled = enabled
        try? store.save(preferences, to: .preferences)
        return AppState.live(store: store, aws: aws, connectionService: MockConnectionService(), syncService: sync)
    }

    @Test func disabledSyncDoesNothing() async {
        let sync = MockSyncService()
        let mac = makeMac(sync: sync, profiles: [profile()], enabled: false)
        await mac.syncNow()
        #expect(mac.syncStatus == .disabled)
        #expect(await sync.saveCount == 0)
    }

    /// 집 Mac → iCloud → 회사 Mac
    @Test func twoMacsShareFavoritesAndAliases() async throws {
        let sync = MockSyncService()
        let home = makeMac(sync: sync, profiles: [profile()])
        await home.syncNow()
        #expect(await sync.document?.profiles.count == 1)

        let office = makeMac(sync: sync, profiles: [])
        await office.syncNow()
        #expect(office.profiles.count == 1)

        office.toggleFavorite(id: profile().id)
        await office.syncNow()
        await home.syncNow()
        #expect(home.profile(id: profile().id)?.isFavorite == true)
        guard case .synced = home.syncStatus else {
            Issue.record("expected synced, got \(home.syncStatus)")
            return
        }
    }

    @Test func concurrentEditsAreSurfacedAndResolvable() async throws {
        let sync = MockSyncService()
        let home = makeMac(sync: sync, profiles: [profile()])
        await home.syncNow()
        let office = makeMac(sync: sync, profiles: [])
        await office.syncNow()

        // 두 Mac이 같은 서버를 서로 다르게 수정
        var homeEdit = home.profile(id: profile().id)!
        homeEdit.sshUsername = "ubuntu"
        home.updateConnectionSettings(profile: homeEdit, settings: home.localSettings(for: homeEdit.id))
        var officeEdit = office.profile(id: profile().id)!
        officeEdit.sshUsername = "admin"
        office.updateConnectionSettings(profile: officeEdit, settings: office.localSettings(for: officeEdit.id))

        await office.syncNow()
        await home.syncNow()

        #expect(home.syncStatus == .conflicts(1))
        #expect(home.profile(id: profile().id)?.sshUsername == "ubuntu")
        #expect(await sync.document?.profiles.first?.sshUsername == "admin")

        await home.resolveConflict(id: profile().id, keep: .keepLocal)
        #expect(home.syncConflicts.isEmpty)
        #expect(await sync.document?.profiles.first?.sshUsername == "ubuntu")

        await office.syncNow()
        #expect(office.profile(id: profile().id)?.sshUsername == "ubuntu")
        #expect(office.syncConflicts.isEmpty)
    }

    @Test func keepRemoteResolution() async throws {
        let sync = MockSyncService()
        let base = profile()
        let home = makeMac(sync: sync, profiles: [base])
        await home.syncNow()

        var remote = base
        remote.groupName = "remote"
        remote.updatedAt = edited
        await sync.setDocument(SyncedProfilesDocument(profiles: [remote]))
        var local = home.profile(id: base.id)!
        local.groupName = "local"
        home.updateConnectionSettings(profile: local, settings: home.localSettings(for: local.id))

        await home.syncNow()
        #expect(home.syncConflicts.count == 1)

        await home.resolveConflict(id: base.id, keep: .keepRemote)
        #expect(home.profile(id: base.id)?.groupName == "remote")
        #expect(home.syncConflicts.isEmpty)
    }

    @Test func failureKeepsLocalDataAndStatus() async {
        let sync = MockSyncService()
        await sync.setFailure(.unavailable("iCloud Drive를 사용할 수 없습니다."))
        let mac = makeMac(sync: sync, profiles: [profile()])
        await mac.syncNow()
        guard case .failed = mac.syncStatus else {
            Issue.record("expected failure")
            return
        }
        #expect(mac.profiles.count == 1)
    }

    @Test func offlineFileVersionChangesAreMerged() async throws {
        let sync = MockSyncService()
        let base = profile()
        let mac = makeMac(sync: sync, profiles: [base])
        await mac.syncNow()

        let versionEdit = edited(base) { $0.isFavorite = true }
        await sync.setConflictVersions([SyncedProfilesDocument(profiles: [versionEdit])])
        await mac.syncNow()

        #expect(mac.profile(id: base.id)?.isFavorite == true)
        #expect(await sync.document?.profiles.first?.isFavorite == true)
        #expect(mac.syncConflicts.isEmpty)
    }
}

@Suite("ICloudDriveSyncService (임시 폴더)")
struct ICloudDriveSyncServiceTests {
    private func makeService() throws -> (ICloudDriveSyncService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EC2DockSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ICloudDriveSyncService(directory: root.appendingPathComponent("EC2Dock", isDirectory: true)), root)
    }

    @Test func emptyThenRoundTrip() async throws {
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try await service.load().document == nil)
        let document = SyncedProfilesDocument(profiles: [profile()])
        try await service.save(document)
        #expect(try await service.load().document == document)
    }

    @Test func savedFileHasNoLocalOnlyData() async throws {
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.save(SyncedProfilesDocument(profiles: SampleData.profiles(now: created)))

        let json = try String(contentsOf: service.directory.appendingPathComponent(ICloudDriveSyncService.fileName), encoding: .utf8)
        for forbidden in ["sshKeyPath", "awsCLIProfileName", "publicIPAddress", "privateIPAddress", "203.0.113", "10.0."] {
            #expect(!json.contains(forbidden), "\(forbidden)")
        }
    }

    /// 해석할 수 없거나 더 새로운 스키마의 파일은 덮어쓰지 않도록 오류로 알린다.
    @Test func corruptOrNewerFilesAreNotAccepted() async throws {
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: service.directory, withIntermediateDirectories: true)
        let url = service.directory.appendingPathComponent(ICloudDriveSyncService.fileName)

        try Data("{broken".utf8).write(to: url)
        await #expect(throws: SyncError.invalidDocument) { try await service.load() }

        try Data(#"{"schemaVersion": 99, "profiles": []}"#.utf8).write(to: url)
        await #expect(throws: SyncError.newerSchema(99)) { try await service.load() }
    }

    @Test func unavailableWhenICloudDriveFolderMissing() async {
        let service = ICloudDriveSyncService(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/EC2Dock"))
        guard case .unavailable = await service.availability() else {
            Issue.record("expected unavailable")
            return
        }
        await #expect(throws: SyncError.self) { try await service.load() }
    }
}
