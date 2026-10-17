import Foundation
import Testing
@testable import EC2DockCore

final class SelectiveFailureStore: LocalStore, @unchecked Sendable {
    private let store = InMemoryStore()
    private let lock = NSLock()
    private var writeFailures: Set<LocalStoreFile> = []
    private var readFailures: Set<LocalStoreFile> = []

    func failWrites(to files: Set<LocalStoreFile>) {
        lock.withLock { writeFailures = files }
    }

    func failReads(from files: Set<LocalStoreFile>) {
        lock.withLock { readFailures = files }
    }

    func load<T: Decodable>(_ type: T.Type, from file: LocalStoreFile) throws -> T? {
        if lock.withLock({ readFailures.contains(file) }) { throw CocoaError(.fileReadNoPermission) }
        return try store.load(type, from: file)
    }

    func save<T: Encodable>(_ value: T, to file: LocalStoreFile) throws {
        if lock.withLock({ writeFailures.contains(file) }) { throw CocoaError(.fileWriteNoPermission) }
        try store.save(value, to: file)
    }
}

@MainActor
@Suite("Persistence error retention")
struct PersistenceErrorTests {
    private func makeState(store: SelectiveFailureStore) -> AppState {
        AppState(profiles: SampleData.profiles(), cachedInstances: [], preferences: AppPreferences(),
                 aws: MockAWSDiscoveryService(accounts: [:], instances: []),
                 connectionService: MockConnectionService(), syncService: MockSyncService(), store: store)
    }

    @Test func unrelatedSaveDoesNotClearError() {
        let store = SelectiveFailureStore()
        let state = makeState(store: store)
        store.failWrites(to: [.profiles])
        let id = state.profiles[0].id
        state.toggleFavorite(id: id)
        #expect(state.persistenceError?.contains(LocalStoreFile.profiles.rawValue) == true)

        state.preferences.defaultAWSProfile = "other"
        #expect(state.persistenceError?.contains(LocalStoreFile.profiles.rawValue) == true)

        store.failWrites(to: [])
        state.toggleFavorite(id: id)
        #expect(state.persistenceError == nil)
    }

    @Test func eachFailedFileMustRecoverBeforeErrorsClear() {
        let store = SelectiveFailureStore()
        let state = makeState(store: store)
        let profile = state.profiles[0]
        store.failWrites(to: [.profiles, .localSettings])
        state.updateConnectionSettings(profile: profile, settings: state.localSettings(for: profile.id))
        #expect(state.persistenceError?.contains(LocalStoreFile.profiles.rawValue) == true)
        #expect(state.persistenceError?.contains(LocalStoreFile.localSettings.rawValue) == true)

        store.failWrites(to: [.localSettings])
        state.toggleFavorite(id: profile.id)
        #expect(state.persistenceError?.contains(LocalStoreFile.profiles.rawValue) == false)
        #expect(state.persistenceError?.contains(LocalStoreFile.localSettings.rawValue) == true)

        store.failWrites(to: [])
        state.updateConnectionSettings(profile: state.profiles[0], settings: state.localSettings(for: profile.id))
        #expect(state.persistenceError == nil)
    }

    @Test func successfulSecondWriteDoesNotHideFirstFailure() {
        let store = SelectiveFailureStore()
        let state = makeState(store: store)
        let profile = state.profiles[0]
        store.failWrites(to: [.profiles])
        state.updateConnectionSettings(profile: profile, settings: state.localSettings(for: profile.id))
        #expect(state.persistenceError?.contains(LocalStoreFile.profiles.rawValue) == true)
    }

    @Test func loadErrorsSurviveUnrelatedSaves() async {
        let store = SelectiveFailureStore()
        store.failReads(from: [.profiles, .instanceCache])
        let state = AppState.live(store: store, aws: MockAWSDiscoveryService(accounts: [:], instances: []),
                                  connectionService: MockConnectionService(), syncService: MockSyncService())
        state.preferences.defaultAWSProfile = "other"
        #expect(state.persistenceError?.contains(LocalStoreFile.profiles.rawValue) == true)
        #expect(state.persistenceError?.contains(LocalStoreFile.instanceCache.rawValue) == true)
    }
}
