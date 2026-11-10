import Foundation
import Testing
@testable import EC2DockCore

@MainActor
@Suite("수동 서버 지원 (Manual Servers)")
struct ManualServerTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 1. Model Decode v1

    @Test func modelDecodeV1JSON() throws {
        // v1 버전에서 직렬화된 JSON (source, host 필드가 없음)
        let v1JSON = """
        {
          "accountAlias" : "acme-prod",
          "accountID" : "111111111111",
          "connectionType" : "directSSH",
          "createdAt" : "2023-11-14T22:13:20Z",
          "displayName" : "prod-web-01",
          "environment" : "Production",
          "groupName" : "web",
          "instanceID" : "i-0123456789abcdef0",
          "isFavorite" : true,
          "region" : "ap-northeast-2",
          "schemaVersion" : 1,
          "sshPort" : 22,
          "sshUsername" : "ec2-user",
          "updatedAt" : "2023-11-14T22:13:20Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(ServerProfile.self, from: Data(v1JSON.utf8))

        #expect(profile.source == .aws)
        #expect(profile.host == nil)
        #expect(!profile.isManual)
        #expect(profile.hostKeyAlias == "i-0123456789abcdef0")
        #expect(profile.id == "111111111111:ap-northeast-2:i-0123456789abcdef0")
    }

    @Test func manualProfileModelPropertiesAndRoundTrip() throws {
        let manual = ServerProfile.manual(
            displayName: "my-onprem-server",
            host: "192.168.1.100",
            environment: "Production",
            groupName: "on-prem",
            isFavorite: true,
            connectionType: .directSSH,
            sshUsername: "admin",
            sshPort: 2222,
            now: fixedDate,
            uuid: "12345678-abcd-ef01-2345-6789abcdef01"
        )

        #expect(manual.source == .manual)
        #expect(manual.isManual)
        #expect(manual.host == "192.168.1.100")
        #expect(manual.hostKeyAlias == nil)
        #expect(manual.id == "manual:12345678-abcd-ef01-2345-6789abcdef01")
        #expect(manual.accountID == "")
        #expect(manual.region == "")
        #expect(manual.schemaVersion == ServerProfile.currentSchemaVersion)
        #expect(manual.isProduction)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manual)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ServerProfile.self, from: data)

        #expect(decoded == manual)
        #expect(decoded.id == manual.id)
        #expect(decoded.source == .manual)
        #expect(decoded.host == "192.168.1.100")
        #expect(decoded.hostKeyAlias == nil)
    }

    // MARK: - 2. Host Validation & Injection

    @Test(arguments: [
        "192.168.1.1",
        "10.0.0.1",
        "127.0.0.1",
        "203.0.113.195",
        "::1",
        "fe80::1",
        "2001:db8::1",
        "2001:0db8:85a3:0000:0000:8a2e:0370:7334",
        "localhost",
        "server.example.com",
        "node-1.internal.corp",
        "my-db-server",
        "a.b.c.d"
    ])
    func validHosts(_ host: String) {
        #expect(InputValidator.isValidHost(host))
    }

    @Test(arguments: [
        "",
        "-oProxyCommand=x",
        "-p22",
        "a b",
        "a;b",
        "$(x)",
        "`x`",
        "a|b",
        "a&b",
        "a>b",
        "a<b",
        "a\nb",
        "a\tb",
        "-host",
        "host-",
        "a..b",
        ".example.com",
        "example.com.",
        "server_name.com",
        "a" + String(repeating: "b", count: 64) + ".com" // label > 63
    ])
    func invalidAndInjectionHosts(_ host: String) {
        #expect(!InputValidator.isValidHost(host))
    }

    @Test func manualProfileValidationSkipsAWSFieldsAndRequiresHost() {
        var profile = ServerProfile.manual(
            displayName: "on-prem",
            host: "192.168.1.10",
            now: fixedDate
        )
        #expect(InputValidator.validate(profile).isEmpty)

        profile.host = "-oProxyCommand=touch /tmp/pwned"
        let issues = InputValidator.validate(profile)
        #expect(issues.map(\.field) == [.host])

        profile.host = nil
        #expect(InputValidator.validate(profile).map(\.field) == [.host])

        let validSettings = LocalConnectionSettings(
            profileID: profile.id,
            awsCLIProfileName: "invalid!profile!name"
        )
        // 수동 서버는 AWS CLI 프로필 검증을 건너뛴다.
        #expect(InputValidator.validate(validSettings, requiresAWSProfile: false).isEmpty)
        #expect(!InputValidator.validate(validSettings, requiresAWSProfile: true).isEmpty)
    }

    // MARK: - 3. Preflight Manual Direct / Bastion

    @Test func preflightManualDirectSSH() throws {
        let manual = ServerProfile.manual(
            displayName: "my-server",
            host: "10.0.0.50",
            now: fixedDate
        )
        let settings = LocalConnectionSettings(profileID: manual.id)

        let target = try ConnectionPreflight.makeTarget(
            profile: manual,
            instance: nil,
            settings: settings
        )

        #expect(target.address == "10.0.0.50")
        #expect(target.instance == nil)
        #expect(target.bastion == nil)
    }

    @Test func preflightManualBastionSSH() throws {
        let bastion = ServerProfile.manual(
            displayName: "manual-bastion",
            host: "bastion.example.com",
            now: fixedDate,
            uuid: "11111111-1111-1111-1111-111111111111"
        )
        let manual = ServerProfile.manual(
            displayName: "internal-server",
            host: "10.0.1.5",
            connectionType: .bastionSSH,
            bastionProfileID: bastion.id,
            now: fixedDate,
            uuid: "22222222-2222-2222-2222-222222222222"
        )
        let settings = LocalConnectionSettings(profileID: manual.id)
        let bastionSettings = LocalConnectionSettings(profileID: bastion.id)

        let target = try ConnectionPreflight.makeTarget(
            profile: manual,
            instance: nil,
            settings: settings,
            bastion: BastionInput(profile: bastion, instance: nil, settings: bastionSettings)
        )

        #expect(target.address == "10.0.1.5")
        #expect(target.instance == nil)
        #expect(target.bastion?.address == "bastion.example.com")
        #expect(target.bastion?.instance == nil)
        #expect(target.bastion?.profile.id == bastion.id)
    }

    @Test func manualSSMIsUnsupported() {
        var manual = ServerProfile.manual(
            displayName: "manual-ssm",
            host: "192.168.1.1",
            now: fixedDate
        )
        manual.connectionType = .ssm
        let settings = LocalConnectionSettings(profileID: manual.id)

        #expect(throws: ConnectionError.unsupportedConnectionType(.ssm)) {
            try ConnectionPreflight.makeTarget(profile: manual, instance: nil, settings: settings)
        }
    }

    // MARK: - 4. AWS Target with Manual Bastion

    @Test func awsTargetWithManualBastion() throws {
        let manualBastion = ServerProfile.manual(
            displayName: "home-vpn-bastion",
            host: "203.0.113.99",
            now: fixedDate,
            uuid: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        )
        let awsProfile = ServerProfile(
            accountID: "111111111111",
            accountAlias: "prod",
            region: "ap-northeast-2",
            instanceID: "i-0123456789abcdef0",
            displayName: "aws-private-db",
            connectionType: .bastionSSH,
            bastionProfileID: manualBastion.id,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let awsInstance = EC2Instance(
            accountID: "111111111111",
            region: "ap-northeast-2",
            instanceID: "i-0123456789abcdef0",
            state: "running",
            privateIPAddress: "10.0.2.15",
            lastFetchedAt: fixedDate
        )
        let awsSettings = LocalConnectionSettings(profileID: awsProfile.id, awsCLIProfileName: "prod")
        let bastionSettings = LocalConnectionSettings(profileID: manualBastion.id)

        let target = try ConnectionPreflight.makeTarget(
            profile: awsProfile,
            instance: awsInstance,
            settings: awsSettings,
            bastion: BastionInput(profile: manualBastion, instance: nil, settings: bastionSettings)
        )

        #expect(target.address == "10.0.2.15")
        #expect(target.instance?.instanceID == "i-0123456789abcdef0")
        #expect(target.bastion?.address == "203.0.113.99")
        #expect(target.bastion?.instance == nil)
    }

    @Test func bastionCandidatesRules() {
        let manual1 = ServerProfile.manual(displayName: "manual-1", host: "1.1.1.1", uuid: "m1")
        let manual2 = ServerProfile.manual(displayName: "manual-2", host: "2.2.2.2", uuid: "m2")
        let awsProd1 = ServerProfile(
            accountID: "111111111111", accountAlias: "prod", region: "ap-northeast-2",
            instanceID: "i-111", displayName: "aws-prod-1", createdAt: fixedDate, updatedAt: fixedDate
        )
        let awsProd2 = ServerProfile(
            accountID: "111111111111", accountAlias: "prod", region: "ap-northeast-2",
            instanceID: "i-222", displayName: "aws-prod-2", createdAt: fixedDate, updatedAt: fixedDate
        )
        let awsDev = ServerProfile(
            accountID: "222222222222", accountAlias: "dev", region: "ap-northeast-2",
            instanceID: "i-333", displayName: "aws-dev", createdAt: fixedDate, updatedAt: fixedDate
        )

        let instProd2 = EC2Instance(
            accountID: "111111111111", region: "ap-northeast-2", instanceID: "i-222",
            state: "running", publicIPAddress: "203.0.113.2", lastFetchedAt: fixedDate
        )

        let state = AppState(
            profiles: [manual1, manual2, awsProd1, awsProd2, awsDev],
            cachedInstances: [instProd2],
            preferences: AppPreferences(),
            aws: MockAWSDiscoveryService(accounts: [:], instances: []),
            connectionService: MockConnectionService(),
            syncService: MockSyncService()
        )

        // 1) AWS 타겟 -> 같은 계정의 공인 IP AWS 서버 + 임의의 수동 서버 (자기 자신 제외)
        let awsCandidates = Set(state.bastionCandidates(for: awsProd1).map(\.displayName))
        #expect(awsCandidates.contains("manual-1"))
        #expect(awsCandidates.contains("manual-2"))
        #expect(awsCandidates.contains("aws-prod-2"))
        #expect(!awsCandidates.contains("aws-prod-1")) // 자기 자신 제외
        #expect(!awsCandidates.contains("aws-dev"))    // 다른 계정 AWS 제외

        // 2) 수동 타겟 -> 임의의 수동 서버만 (자기 자신 제외, AWS 서버 제외)
        let manualCandidates = Set(state.bastionCandidates(for: manual1).map(\.displayName))
        #expect(manualCandidates.contains("manual-2"))
        #expect(!manualCandidates.contains("manual-1")) // 자기 자신 제외
        #expect(!manualCandidates.contains("aws-prod-2")) // AWS 서버 제외
    }

    // MARK: - 5. SSH / SFTP Arguments without HostKeyAlias for Manual

    @Test func sshAndSFTPArgsWithoutHostKeyAliasForManual() throws {
        let manual = ServerProfile.manual(
            displayName: "my-host",
            host: "server.example.com",
            sshUsername: "deploy",
            sshPort: 2200,
            now: fixedDate,
            uuid: "abcdefab-cdef-abcd-efab-cdefabcdefab"
        )
        let settings = LocalConnectionSettings(profileID: manual.id)
        let target = ConnectionTarget(profile: manual, instance: nil, address: "server.example.com", settings: settings)

        let builder = SSHCommandBuilder(keyFileStatus: { _ in .ok })
        let sshCmd = try builder.command(for: target)
        let sftpCmd = try builder.sftpCommand(for: target, batchFile: "/tmp/batch.txt", controlPath: "/tmp/cp")

        // 1) SSH command args
        #expect(!sshCmd.arguments.contains { $0.contains("HostKeyAlias") })
        #expect(sshCmd.arguments.contains("-p"))
        #expect(sshCmd.arguments.contains("2200"))
        #expect(sshCmd.arguments.last == "deploy@server.example.com")

        // 2) SFTP command args
        #expect(!sftpCmd.arguments.contains { $0.contains("HostKeyAlias") })
        #expect(sftpCmd.arguments.contains("-P"))
        #expect(sftpCmd.arguments.contains("2200"))
        #expect(sftpCmd.arguments.last == "deploy@server.example.com")

        // 3) AWS 서버는 HostKeyAlias가 포함되어야 함
        let aws = ServerProfile(
            accountID: "111111111111", accountAlias: "acme", region: "ap-northeast-2",
            instanceID: "i-0123456789abcdef0", displayName: "aws-web",
            createdAt: fixedDate, updatedAt: fixedDate
        )
        let awsSettings = LocalConnectionSettings(profileID: aws.id, awsCLIProfileName: "acme")
        let awsTarget = ConnectionTarget(profile: aws, instance: nil, address: "203.0.113.10", settings: awsSettings)

        let awsSSH = try builder.command(for: awsTarget)
        #expect(awsSSH.arguments.contains("HostKeyAlias=i-0123456789abcdef0"))
    }

    @Test func manualBastionSSHProxyCommandHasNoHostKeyAlias() throws {
        let bastion = ServerProfile.manual(
            displayName: "manual-bastion",
            host: "bastion.example.com",
            sshUsername: "jumpuser",
            sshPort: 22,
            now: fixedDate,
            uuid: "bastion-uuid"
        )
        let manual = ServerProfile.manual(
            displayName: "target",
            host: "10.0.0.1",
            connectionType: .bastionSSH,
            bastionProfileID: bastion.id,
            now: fixedDate,
            uuid: "target-uuid"
        )
        let settings = LocalConnectionSettings(profileID: manual.id)
        let bastionSettings = LocalConnectionSettings(profileID: bastion.id)

        let hop = BastionHop(profile: bastion, instance: nil, address: "bastion.example.com", settings: bastionSettings)
        let target = ConnectionTarget(profile: manual, instance: nil, address: "10.0.0.1", settings: settings, bastion: hop)

        let builder = SSHCommandBuilder(keyFileStatus: { _ in .ok })
        let cmd = try builder.command(for: target)

        // ProxyCommand 인자 확인
        let proxyArg = try #require(cmd.arguments.first { $0.hasPrefix("ProxyCommand=") })
        #expect(!proxyArg.contains("HostKeyAlias"))
        #expect(proxyArg.contains("bastion.example.com"))
        #expect(proxyArg.contains("-W 10.0.0.1:22"))
    }

    // MARK: - 6. Refresh Keeps Manual

    @Test func refreshKeepsManualProfilesUnaltered() async {
        let aws = ServerProfile(
            accountID: "111111111111", accountAlias: "acme-prod", region: "ap-northeast-2",
            instanceID: "i-0a1b2c3d4e5f60001", displayName: "prod-web-01",
            createdAt: fixedDate, updatedAt: fixedDate
        )
        let manual = ServerProfile.manual(
            displayName: "my-gateway",
            host: "192.168.1.1",
            now: fixedDate,
            uuid: "gateway-uuid"
        )

        let state = AppState(
            profiles: [aws, manual],
            cachedInstances: [],
            preferences: AppPreferences(
                defaultAWSProfile: "acme-prod",
                enabledAWSProfiles: ["acme-prod"],
                defaultRegion: "ap-northeast-2",
                regions: ["ap-northeast-2"]
            ),
            aws: MockAWSDiscoveryService(
                accounts: ["acme-prod": "111111111111"],
                instances: [
                    EC2Instance(accountID: "111111111111", region: "ap-northeast-2", instanceID: "i-0a1b2c3d4e5f60001",
                                state: "running", publicIPAddress: "203.0.113.50", lastFetchedAt: fixedDate)
                ]
            ),
            connectionService: MockConnectionService(),
            syncService: MockSyncService()
        )

        await state.refresh()

        // 1) 수동 서버는 refresh 후에도 그대로 남아 있다.
        let foundManual = state.profile(id: manual.id)
        #expect(foundManual != nil)
        #expect(foundManual?.displayName == "my-gateway")
        #expect(foundManual?.host == "192.168.1.1")
        #expect(foundManual?.isManual == true)

        // 2) refreshInstance for manual profile -> no AWS call, returns nil
        let refreshedInstance = try? await state.refreshInstance(id: manual.id)
        #expect(refreshedInstance == nil)

        // 3) accounts summaries excludes manual
        #expect(state.accounts.allSatisfy { $0.accountID == "111111111111" })
        #expect(!state.accounts.contains { $0.accountID == "" })

        // 4) Search scopes find host
        let items = state.items(filter: .all, query: "192.168.1.1", scope: .all)
        #expect(items.map { $0.id } == [manual.id])

        let publicIPSearch = state.items(filter: .all, query: "192.168.1.1", scope: .publicIP)
        #expect(publicIPSearch.map { $0.id } == [manual.id])

        let manualFilterItems = state.items(filter: .manual, query: "")
        #expect(manualFilterItems.map { $0.id } == [manual.id])
    }

    // MARK: - 7. Sync Version 1 vs 2

    @Test func syncDocumentSchemaVersionSelection() {
        let aws = ServerProfile(
            accountID: "111111111111", accountAlias: "acme", region: "ap-northeast-2",
            instanceID: "i-1", displayName: "aws-server", createdAt: fixedDate, updatedAt: fixedDate
        )
        let manual = ServerProfile.manual(
            displayName: "manual-server", host: "1.2.3.4", now: fixedDate
        )

        // 1) AWS 프로필만 있으면 schemaVersion = 1
        let docV1 = SyncedProfilesDocument(profiles: [aws])
        #expect(docV1.schemaVersion == 1)

        // 2) 수동 프로필이 포함되면 schemaVersion = 2
        let docV2 = SyncedProfilesDocument(profiles: [aws, manual])
        #expect(docV2.schemaVersion == 2)

        // 3) 수동 프로필 tombstone이 있으면 schemaVersion = 2
        let docV2Tombstone = SyncedProfilesDocument(
            profiles: [aws],
            deletedProfiles: [ProfileTombstone(profile: manual, deletedAt: fixedDate)]
        )
        #expect(docV2Tombstone.schemaVersion == 2)
    }

    @Test func iCloudSyncDecodesV1AndV2Documents() throws {
        // v1 문서 디코딩
        let v1JSON = """
        {
          "schemaVersion" : 1,
          "profiles" : [
            {
              "accountAlias" : "acme-prod",
              "accountID" : "111111111111",
              "connectionType" : "directSSH",
              "createdAt" : "2023-11-14T22:13:20Z",
              "displayName" : "prod-web-01",
              "environment" : "Production",
              "groupName" : "web",
              "instanceID" : "i-0123456789abcdef0",
              "isFavorite" : true,
              "region" : "ap-northeast-2",
              "schemaVersion" : 1,
              "sshPort" : 22,
              "sshUsername" : "ec2-user",
              "updatedAt" : "2023-11-14T22:13:20Z"
            }
          ]
        }
        """
        let decodedV1 = try ICloudDriveSyncService.decode(Data(v1JSON.utf8))
        #expect(decodedV1.schemaVersion == 1)
        #expect(decodedV1.profiles.count == 1)
        #expect(decodedV1.profiles[0].source == .aws)

        // v2 문서 디코딩 (수동 서버 포함)
        let manual = ServerProfile.manual(displayName: "on-prem", host: "192.168.1.10", now: fixedDate)
        let docV2 = SyncedProfilesDocument(profiles: [manual])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let v2Data = try encoder.encode(docV2)

        let decodedV2 = try ICloudDriveSyncService.decode(v2Data)
        #expect(decodedV2.schemaVersion == 2)
        #expect(decodedV2.profiles.count == 1)
        #expect(decodedV2.profiles[0].isManual)
        #expect(decodedV2.profiles[0].host == "192.168.1.10")

        // 미래 버전(v3)은 newerSchema 오류 발생
        let v3JSON = """
        {
          "schemaVersion" : 3,
          "profiles" : []
        }
        """
        #expect(throws: SyncError.newerSchema(3)) {
            try ICloudDriveSyncService.decode(Data(v3JSON.utf8))
        }
    }

    @Test func profileSyncMergerIncludesHostInDifferencesForManual() {
        let local = ServerProfile.manual(
            displayName: "server", host: "192.168.1.10", now: fixedDate, uuid: "shared-id"
        )
        var remote = ServerProfile.manual(
            displayName: "server", host: "192.168.1.20", now: fixedDate, uuid: "shared-id"
        )
        remote.updatedAt = fixedDate.addingTimeInterval(10)

        let conflict = SyncConflict(local: local, remote: remote)
        let hostDiff = conflict.differences.first { $0.label == "호스트" }

        #expect(hostDiff != nil)
        #expect(hostDiff?.local == "192.168.1.10")
        #expect(hostDiff?.remote == "192.168.1.20")
    }

    // MARK: - 8. Delete & Restore

    @Test func deleteAndRestoreManualProfile() {
        let manual = ServerProfile.manual(
            displayName: "manual-to-delete",
            host: "10.0.0.1",
            now: fixedDate,
            uuid: "del-uuid"
        )
        let settings = LocalConnectionSettings(profileID: manual.id)
        let state = AppState(
            profiles: [],
            cachedInstances: [],
            preferences: AppPreferences(),
            aws: MockAWSDiscoveryService(accounts: [:], instances: []),
            connectionService: MockConnectionService(),
            syncService: MockSyncService()
        )

        // 1) 추가
        let addIssues = state.addManualServer(profile: manual, settings: settings)
        #expect(addIssues.isEmpty)
        #expect(state.profile(id: manual.id) != nil)

        // 2) 삭제
        state.deleteProfile(id: manual.id)
        #expect(state.profile(id: manual.id) == nil)
        #expect(state.deletedProfiles.contains { $0.id == manual.id })
        let tombstone = state.deletedProfiles.first { $0.id == manual.id }
        #expect(tombstone?.profile.isManual == true)
        #expect(tombstone?.profile.host == "10.0.0.1")

        // 3) 복원
        state.restoreDeletedProfile(id: manual.id)
        #expect(!state.deletedProfiles.contains { $0.id == manual.id })
        let restored = state.profile(id: manual.id)
        #expect(restored != nil)
        #expect(restored?.isManual == true)
        #expect(restored?.host == "10.0.0.1")
        #expect(restored?.displayName == "manual-to-delete")
    }
}
