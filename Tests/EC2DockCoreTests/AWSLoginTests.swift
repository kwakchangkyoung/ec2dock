import Foundation
import Testing
@testable import EC2DockCore

@Suite("AWS login flow")
struct AWSLoginTests {
    private let awsURL = URL(fileURLWithPath: "/opt/homebrew/bin/aws")

    @Test func loginProfileIsOnlyForCredentialErrors() {
        #expect(AWSDiscoveryError.credentialsExpired(profile: "p").loginProfile == "p")
        #expect(AWSDiscoveryError.noCredentials(profile: "p").loginProfile == "p")
        #expect(AWSDiscoveryError.accessDenied(action: "ec2:DescribeInstances").loginProfile == nil)
        #expect(AWSDiscoveryError.networkUnavailable.loginProfile == nil)
        #expect(ConnectionError.discoveryFailed(.credentialsExpired(profile: "p")).loginProfile == "p")
        #expect(ConnectionError.noPublicIP.loginProfile == nil)
    }

    @Test func consoleProfileUsesAWSLogin() async throws {
        let runner = FakeRunner()   // configure get 응답이 없으면 실패 코드 → SSO 설정 없음
        let service = AWSCLIDiscoveryService(runner: runner, locate: { [awsURL] in awsURL })
        let command = try await service.loginCommand(profile: "my-profile")
        #expect(command.executable == awsURL.path)
        #expect(command.arguments == ["login", "--profile", "my-profile"])
    }

    @Test func ssoProfileUsesSSOLogin() async throws {
        let runner = FakeRunner()
        await runner.respond(to: ["configure", "get", "sso_session"], stdout: "my-sso\n")
        let service = AWSCLIDiscoveryService(runner: runner, locate: { [awsURL] in awsURL })
        let command = try await service.loginCommand(profile: "work")
        #expect(command.arguments == ["sso", "login", "--profile", "work"])
        #expect(await runner.calls.first == ["configure", "get", "sso_session", "--profile", "work", "--no-cli-pager"])
    }

    @Test func invalidProfileOrMissingCLIIsRejected() async {
        let runner = FakeRunner()
        let service = AWSCLIDiscoveryService(runner: runner, locate: { [awsURL] in awsURL })
        await #expect(throws: AWSDiscoveryError.invalidArgument("프로필 이름")) {
            try await service.loginCommand(profile: "p; rm -rf ~")
        }
        await #expect(throws: AWSDiscoveryError.cliNotFound) {
            try await AWSCLIDiscoveryService(runner: runner, locate: { nil }).loginCommand(profile: "p")
        }
        #expect(await runner.calls.isEmpty)
    }

    @MainActor
    @Test func expiredCredentialsOfferLoginThenRefreshSucceeds() async throws {
        let aws = MockAWSDiscoveryService(accounts: SampleData.awsProfiles, instances: SampleData.liveInstances())
        let state = AppState(profiles: [], cachedInstances: [], preferences: SampleData.preferences, aws: aws,
                             connectionService: MockConnectionService(), syncService: MockSyncService())
        await aws.setFailure(.credentialsExpired(profile: "acme-prod"))
        await state.refresh()
        guard case .failed(let failures) = state.refreshStatus else {
            Issue.record("expected failure")
            return
        }
        #expect(failures.first?.loginProfile == "acme-prod")

        let session = try await state.loginSession(for: "acme-prod")
        #expect(session.kind == .awsLogin(awsProfile: "acme-prod"))
        #expect(session.profileID == nil)
        #expect(!session.isProduction)

        // Mock은 로그인 명령을 만들면 로그인된 것으로 간주한다.
        await state.refresh()
        guard case .succeeded = state.refreshStatus else {
            Issue.record("expected success after login, got \(state.refreshStatus)")
            return
        }
    }
}

@Suite("Add AWS account")
struct AddAWSAccountTests {
    private let awsURL = URL(fileURLWithPath: "/opt/homebrew/bin/aws")

    @Test func commandsPerMethod() async throws {
        let service = AWSCLIDiscoveryService(runner: FakeRunner(), locate: { [awsURL] in awsURL })
        #expect(try await service.addAccountCommand(profile: "work", method: .consoleLogin).arguments
                == ["login", "--profile", "work"])
        #expect(try await service.addAccountCommand(profile: "work", method: .identityCenter).arguments
                == ["configure", "sso", "--profile", "work"])
    }

    /// 장기 액세스 키를 만드는 방식은 제공하지 않는다.
    @Test func noLongTermKeyMethod() {
        for method in AWSAccountSetupMethod.allCases {
            #expect(method.arguments != ["configure"])
        }
    }

    @Test func invalidProfileNameIsRejected() async {
        let runner = FakeRunner()
        let service = AWSCLIDiscoveryService(runner: runner, locate: { [awsURL] in awsURL })
        await #expect(throws: AWSDiscoveryError.invalidArgument("프로필 이름")) {
            try await service.addAccountCommand(profile: "--debug", method: .consoleLogin)
        }
        #expect(await runner.calls.isEmpty)
    }

    @MainActor
    private func makeState(enabled: [String], defaultProfile: String) -> (AppState, MockAWSDiscoveryService) {
        let aws = MockAWSDiscoveryService(accounts: ["acme-prod": SampleData.prodAccountID],
                                          instances: SampleData.liveInstances())
        var preferences = SampleData.preferences
        preferences.enabledAWSProfiles = enabled
        preferences.defaultAWSProfile = defaultProfile
        let state = AppState(profiles: [], cachedInstances: [], preferences: preferences, aws: aws,
                             connectionService: MockConnectionService(), syncService: MockSyncService())
        return (state, aws)
    }

    /// 조회 대상이 비어 있었다면(기본 프로필만 조회) 기본 프로필도 함께 남긴다.
    @MainActor
    @Test func completionKeepsDefaultProfileAndAddsNewAccount() async throws {
        let (state, _) = makeState(enabled: [], defaultProfile: "acme-prod")
        let session = try await state.addAccountSession(profile: "acme-dev", method: .consoleLogin)
        #expect(session.kind == .awsLogin(awsProfile: "acme-dev"))

        await state.completeAccountAddition(profile: "acme-dev")

        #expect(state.preferences.enabledAWSProfiles == ["acme-dev", "acme-prod"])
        #expect(Set(state.accounts.map(\.accountID)) == [SampleData.prodAccountID, SampleData.devAccountID])
    }

    @MainActor
    @Test func completionDoesNotDuplicate() async throws {
        let (state, _) = makeState(enabled: ["acme-prod"], defaultProfile: "acme-prod")
        await state.completeAccountAddition(profile: "acme-prod")
        #expect(state.preferences.enabledAWSProfiles == ["acme-prod"])
    }
}

@MainActor
@Suite("Accounts sidebar & mapping")
struct AccountsSidebarTests {
    /// 조회 대상이지만 아직 조회하지 않은 프로필도 사이드바에 "조회 전"으로 보인다.
    @Test func pendingProfileAppearsThenResolvesAfterRefresh() async {
        let aws = MockAWSDiscoveryService(accounts: ["acme-prod": SampleData.prodAccountID, "empty": "333333333333"],
                                          instances: SampleData.liveInstances())
        var preferences = SampleData.preferences
        preferences.enabledAWSProfiles = ["acme-prod", "empty"]
        let state = AppState(profiles: [], cachedInstances: [], preferences: preferences, aws: aws,
                             connectionService: MockConnectionService(), syncService: MockSyncService())
        await state.reloadAWSProfiles()

        #expect(state.accounts.map(\.alias) == ["acme-prod", "empty"])
        let allPending = state.accounts.allSatisfy { $0.isPending }
        #expect(allPending)

        await state.refresh()
        let empty = state.accounts.first { $0.alias == "empty" }
        #expect(empty?.isPending == false)
        #expect(empty?.accountID == "333333333333")
        #expect(empty?.serverCount == 0)
        #expect(state.accounts.first { $0.alias == "acme-prod" }?.serverCount == 4)
        #expect(state.accounts.count == 2)   // 서버가 있는 계정과 중복되지 않는다
    }

    /// 계정 ↔ 프로필 대응을 저장해, 재시작 후 새로고침 없이도 올바른 프로필로 "다시 조회"한다.
    @Test func accountProfileMappingSurvivesRelaunch() async throws {
        let aws = MockAWSDiscoveryService(accounts: SampleData.awsProfiles, instances: SampleData.liveInstances())
        let store = InMemoryStore()
        try store.save(SampleData.preferences, to: .preferences)
        let first = AppState.live(store: store, aws: aws, connectionService: MockConnectionService(), syncService: MockSyncService())
        await first.refresh()

        let relaunched = AppState.live(store: store, aws: aws, connectionService: MockConnectionService(), syncService: MockSyncService())
        let devDB = ServerProfile.makeID(accountID: SampleData.devAccountID, region: SampleData.seoul, instanceID: SampleData.devDBID)
        #expect(relaunched.localSettings(for: devDB).awsCLIProfileName == "acme-dev")
        let fresh = try await relaunched.refreshInstance(id: devDB)
        #expect(fresh != nil)
    }

    @Test func isLoggedInReflectsCallerIdentity() async {
        let aws = MockAWSDiscoveryService(accounts: SampleData.awsProfiles, instances: [])
        let state = AppState(profiles: [], cachedInstances: [], preferences: SampleData.preferences, aws: aws,
                             connectionService: MockConnectionService(), syncService: MockSyncService())
        #expect(await state.isLoggedIn(awsProfile: "acme-prod"))
        #expect(await !state.isLoggedIn(awsProfile: "unknown"))
        await aws.setFailure(.credentialsExpired(profile: "acme-prod"))
        #expect(await !state.isLoggedIn(awsProfile: "acme-prod"))
    }
}

@MainActor
@Suite("Account labels")
struct AccountLabelTests {
    /// 두 프로필(my-profile, second-profile)이 같은 계정인 경우. 처음엔 my-profile로 발견했고,
    /// 이후 my-profile을 끄고 second-profile로 조회하면 사이드바·목록에 second-profile로 보여야 한다.
    @Test func labelFollowsCurrentProfileForSameAccount() async {
        let aws = MockAWSDiscoveryService(
            accounts: ["my-profile": SampleData.prodAccountID, "second-profile": SampleData.prodAccountID, "other": SampleData.devAccountID],
            instances: SampleData.liveInstances())
        var preferences = SampleData.preferences
        preferences.enabledAWSProfiles = ["my-profile", "other"]
        let state = AppState(profiles: [], cachedInstances: [], preferences: preferences, aws: aws,
                             connectionService: MockConnectionService(), syncService: MockSyncService())
        await state.reloadAWSProfiles()
        await state.refresh()
        #expect(state.accounts.map(\.alias) == ["my-profile", "other"])

        state.preferences.enabledAWSProfiles = ["second-profile"]
        await state.refresh()

        let prod = state.accounts.first { $0.accountID == SampleData.prodAccountID }
        #expect(prod?.alias == "second-profile")
        #expect(prod?.isScanned == true)
        #expect(state.accountLabel(for: SampleData.prodAccountID) == "second-profile")

        // 조회 대상에서 뺀 계정은 서버가 남아 있어도 "조회 안 함"으로 구분된다.
        let dev = state.accounts.first { $0.accountID == SampleData.devAccountID }
        #expect(dev?.isScanned == false)
        #expect(state.accounts.count == 2)

        // 저장된(동기화되는) 별칭은 바꾸지 않는다.
        #expect(state.profiles.first { $0.accountID == SampleData.prodAccountID }?.accountAlias == "my-profile")
    }
}
