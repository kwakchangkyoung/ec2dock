import Foundation
import Testing
@testable import EC2DockCore

private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("목록 정렬·묶기")
struct ListSortingGroupingTests {
    private let items: [ServerListItem] = {
        let instances = Dictionary(uniqueKeysWithValues: SampleData.cachedInstances(now: fixedDate).map { ($0.id, $0) })
        return SampleData.profiles(now: fixedDate).map { ServerListItem(profile: $0, instance: instances[$0.id]) }
    }()

    @Test func sortByNameIsDefault() {
        let names = ServerSearch.sorted(items, by: .name).map(\.profile.displayName)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    /// 실행 중 → 중지 → 종료 순, 같은 상태끼리는 이름순
    @Test func sortByStatePutsRunningFirst() {
        let sorted = ServerSearch.sorted(items, by: .state)
        let states = sorted.map(\.stateLabel)
        #expect(states.first == "running")
        #expect(states.last == "terminated")
        #expect(states.firstIndex(of: "stopped")! > states.lastIndex(of: "running")!)
        let running = sorted.filter { $0.stateLabel == "running" }.map(\.profile.displayName)
        #expect(running == running.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func sortByAccountUsesLabels() {
        let sorted = ServerSearch.sorted(items, by: .account) { $0 == SampleData.devAccountID ? "a-dev" : "z-prod" }
        #expect(sorted.first?.profile.accountID == SampleData.devAccountID)
        #expect(sorted.last?.profile.accountID == SampleData.prodAccountID)
    }

    @Test func noGroupingReturnsSingleUntitledSection() {
        let sections = ServerSearch.sections(items, by: .none)
        #expect(sections.count == 1)
        #expect(sections[0].title.isEmpty)
        #expect(sections[0].items.count == items.count)
    }

    @Test func groupingByEnvironment() {
        let sections = ServerSearch.sections(items, by: .environment)
        #expect(sections.map(\.title) == ["Development", "Production"])
        #expect(sections.map { $0.items.count } == [3, 4])
    }

    /// 그룹이 비어 있는 서버는 마지막 "미지정" 구역으로 간다.
    @Test func ungroupedServersGoLast() {
        var profile = SampleData.profiles(now: fixedDate)[0]
        profile.groupName = ""
        let extra = ServerListItem(profile: profile, instance: nil)
        let sections = ServerSearch.sections(items.filter { $0.id != extra.id } + [extra], by: .group)
        #expect(sections.last?.title == "미지정")
        let lastIDs = sections.last?.items.map(\.id) ?? []
        #expect(lastIDs.contains(extra.id))
        #expect(sections.dropLast().allSatisfy { $0.title != "미지정" })
    }
}

@Suite("설정 확장")
struct PreferencesExtensionTests {
    @Test func fontSizeIsClamped() {
        var preferences = AppPreferences()
        #expect(preferences.terminalFontSize == AppPreferences.defaultTerminalFontSize)
        for _ in 0..<50 { preferences.adjustTerminalFontSize(by: 1) }
        #expect(preferences.terminalFontSize == AppPreferences.terminalFontSizeRange.upperBound)
        for _ in 0..<50 { preferences.adjustTerminalFontSize(by: -1) }
        #expect(preferences.terminalFontSize == AppPreferences.terminalFontSizeRange.lowerBound)
    }

    /// 이전 버전 설정 파일(새 항목·알 수 없는 값 포함)도 읽힌다.
    @Test func olderPreferencesFileStillDecodes() throws {
        let json = #"{"defaultAWSProfile":"work","logLevel":"debug","listSort":"unknown-value"}"#
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
        #expect(preferences.defaultAWSProfile == "work")
        #expect(preferences.listSort == .name)
        #expect(preferences.listDensity == .comfortable)
        #expect(preferences.terminalTheme == .dark)
        #expect(preferences.autoFocusTerminal)
        #expect(!preferences.iTermOpensNewTab)
    }

    @Test func newFieldsRoundTrip() throws {
        var preferences = AppPreferences()
        preferences.listGrouping = .account
        preferences.terminalTheme = .light
        preferences.terminalFontSize = 16
        preferences.iTermOpensNewTab = true
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded == preferences)
    }
}

@Suite("새로고침 진행률·iTerm2 새 탭")
struct ProgressAndNewTabTests {
    @MainActor
    @Test func progressIsClearedAfterRefresh() async {
        let state = AppState.sample()
        #expect(state.refreshProgress == nil)
        await state.refresh()
        #expect(state.refreshProgress == nil)
        guard case .succeeded = state.refreshStatus else {
            Issue.record("expected success")
            return
        }
    }

    @Test func iTermNewTabScriptCreatesTabWhenWindowExists() {
        let script = AppleScriptTerminalLauncher.scriptArguments(for: .iTerm2, newTab: true).joined(separator: "\n")
        #expect(script.contains("create tab with default profile"))
        #expect(script.contains("create window with default profile"))   // 창이 없을 때
        #expect(script.contains("item 1 of argv"))
        let windowOnly = AppleScriptTerminalLauncher.scriptArguments(for: .iTerm2).joined(separator: "\n")
        #expect(!windowOnly.contains("create tab"))
    }

    @Test func newTabPreferenceReachesLauncher() async throws {
        let launcher = MockTerminalLauncher()
        let service = TerminalConnectionService(builder: SSHCommandBuilder { _ in .ok }, launcher: launcher)
        let profile = ServerProfile(accountID: "111111111111", accountAlias: "acme", region: "ap-northeast-2",
                                    instanceID: "i-0123456789abcdef0", displayName: "web", createdAt: fixedDate, updatedAt: fixedDate)
        let instance = EC2Instance(accountID: "111111111111", region: "ap-northeast-2", instanceID: "i-0123456789abcdef0",
                                   state: "running", publicIPAddress: "203.0.113.25", lastFetchedAt: fixedDate)
        let target = try ConnectionPreflight.makeTarget(profile: profile, instance: instance,
                                                        settings: LocalConnectionSettings(profileID: profile.id, awsCLIProfileName: "acme"))
        _ = try await service.connect(target, in: .iTerm2, preferNewTab: true)
        _ = try await service.connect(target, in: .iTerm2)
        #expect(await launcher.launched.map(\.newTab) == [true, false])
    }
}
