import Foundation
import Testing
@testable import EC2DockCore

private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("InputValidator")
struct InputValidatorTests {
    @Test(arguments: ["i-0123abcd", "i-0123456789abcdef0"])
    func validInstanceIDs(_ value: String) {
        #expect(InputValidator.isValidInstanceID(value))
    }

    @Test(arguments: ["", "i-", "i-XYZ12345", "0123456789abcdef0", "i-0123abcd; rm -rf /", "i-0123abcd\n", "-i-0123abcd"])
    func invalidInstanceIDs(_ value: String) {
        #expect(!InputValidator.isValidInstanceID(value))
    }

    @Test(arguments: ["ap-northeast-2", "us-east-1", "us-gov-west-1", "eu-central-2"])
    func validRegions(_ value: String) {
        #expect(InputValidator.isValidRegion(value))
    }

    @Test(arguments: ["", "seoul", "AP-NORTHEAST-2", "us-east-1 --profile x", "us-east-1;id", "--region"])
    func invalidRegions(_ value: String) {
        #expect(!InputValidator.isValidRegion(value))
    }

    @Test(arguments: ["ec2-user", "ubuntu", "_svc", "deploy.bot"])
    func validUsernames(_ value: String) {
        #expect(InputValidator.isValidSSHUsername(value))
    }

    /// 명령/옵션 삽입 시도 문자열 (설계서 12.3)
    @Test(arguments: [
        "", "-oProxyCommand=sh", "root;id", "a b", "user@host", "$(whoami)", "`id`",
        "user\nid", "name'\"", String(repeating: "a", count: 33),
    ])
    func invalidUsernames(_ value: String) {
        #expect(!InputValidator.isValidSSHUsername(value))
    }

    @Test func portRange() {
        #expect(InputValidator.isValidPort(22))
        #expect(InputValidator.isValidPort(65535))
        #expect(!InputValidator.isValidPort(0))
        #expect(!InputValidator.isValidPort(70000))
    }

    @Test func awsProfileNames() {
        #expect(InputValidator.isValidAWSProfileName("acme-prod"))
        #expect(InputValidator.isValidAWSProfileName("default"))
        #expect(!InputValidator.isValidAWSProfileName("-x"))
        #expect(!InputValidator.isValidAWSProfileName("prod --debug"))
        #expect(!InputValidator.isValidAWSProfileName("prod;id"))
    }

    @Test func sshKeyPaths() {
        #expect(InputValidator.isValidSSHKeyPath("~/.ssh/id_ed25519"))
        #expect(InputValidator.isValidSSHKeyPath("/Users/me/keys/a.pem"))
        #expect(!InputValidator.isValidSSHKeyPath("relative/key.pem"))
        #expect(!InputValidator.isValidSSHKeyPath("-oProxyCommand=sh"))
        #expect(!InputValidator.isValidSSHKeyPath("/tmp/a\nb"))
    }

    @Test func bastionCannotPointToItself() {
        var profile = SampleData.profiles(now: fixedDate)[0]
        profile.connectionType = .bastionSSH
        profile.bastionProfileID = profile.id
        #expect(InputValidator.validate(profile).map(\.field) == [.bastionProfile])
    }
}

@Suite("ConnectionPreflight")
struct ConnectionPreflightTests {
    private func profile(_ type: ConnectionType, bastion: String? = "b") -> ServerProfile {
        ServerProfile(accountID: "111111111111", accountAlias: "acme", region: "ap-northeast-2",
                      instanceID: "i-0123456789abcdef0", displayName: "web", connectionType: type,
                      bastionProfileID: bastion, createdAt: fixedDate, updatedAt: fixedDate)
    }

    private func instance(state: String = "running", publicIP: String? = "203.0.113.9",
                          privateIP: String? = "10.0.0.9") -> EC2Instance {
        EC2Instance(accountID: "111111111111", region: "ap-northeast-2", instanceID: "i-0123456789abcdef0",
                    state: state, publicIPAddress: publicIP, privateIPAddress: privateIP, lastFetchedAt: fixedDate)
    }

    private func settings(_ p: ServerProfile) -> LocalConnectionSettings {
        LocalConnectionSettings(profileID: p.id, awsCLIProfileName: "acme")
    }

    private func target(_ p: ServerProfile, _ i: EC2Instance?) throws -> ConnectionTarget {
        try ConnectionPreflight.makeTarget(profile: p, instance: i, settings: settings(p))
    }

    @Test func directSSHUsesPublicIP() throws {
        let p = profile(.directSSH)
        #expect(try target(p, instance()).address == "203.0.113.9")
    }

    @Test func directSSHWithoutPublicIPFails() {
        let p = profile(.directSSH)
        #expect(throws: ConnectionError.noPublicIP) { try target(p, instance(publicIP: nil)) }
    }

    private let bastionProfile = ServerProfile(accountID: "111111111111", accountAlias: "acme", region: "ap-northeast-2",
                                               instanceID: "i-0aaaaaaaaaaaaaaa1", displayName: "bastion",
                                               createdAt: fixedDate, updatedAt: fixedDate)

    private func bastionInput(state: String = "running", publicIP: String? = "203.0.113.5",
                              profile: ServerProfile? = nil) -> BastionInput {
        let p = profile ?? bastionProfile
        let instance = EC2Instance(accountID: p.accountID, region: p.region, instanceID: p.instanceID,
                                   state: state, publicIPAddress: publicIP, lastFetchedAt: fixedDate)
        return BastionInput(profile: p, instance: instance, settings: settings(p))
    }

    private func bastionTarget(_ input: BastionInput?) throws -> ConnectionTarget {
        let p = profile(.bastionSSH, bastion: bastionProfile.id)
        return try ConnectionPreflight.makeTarget(profile: p, instance: instance(publicIP: nil), settings: settings(p), bastion: input)
    }

    @Test func bastionUsesPrivateIPAndBastionPublicIP() throws {
        let target = try bastionTarget(bastionInput())
        #expect(target.address == "10.0.0.9")
        #expect(target.bastion?.address == "203.0.113.5")
        #expect(target.bastion?.profile.id == bastionProfile.id)
    }

    @Test func bastionWithoutBastionProfileFails() {
        // 형식 검증 단계에서 먼저 걸린다.
        let p = profile(.bastionSSH, bastion: nil)
        #expect(throws: ConnectionError.self) { try target(p, instance()) }
    }

    @Test func bastionProblemsAreReported() {
        #expect(throws: ConnectionError.bastionNotFound) { try bastionTarget(nil) }
        #expect(throws: ConnectionError.bastionNotRunning(state: "stopped")) { try bastionTarget(bastionInput(state: "stopped")) }
        #expect(throws: ConnectionError.bastionNoPublicIP) { try bastionTarget(bastionInput(publicIP: nil)) }

        var otherAccount = bastionProfile
        otherAccount.accountID = "222222222222"
        #expect(throws: ConnectionError.bastionNotFound) { try bastionTarget(bastionInput(profile: otherAccount)) }
    }

    @Test func bastionWithInvalidUsernameIsRejected() {
        var bad = bastionProfile
        bad.sshUsername = "-oProxyCommand=sh"
        #expect(throws: ConnectionError.self) { try bastionTarget(bastionInput(profile: bad)) }
    }

    @Test func ssmIsNotSupportedYet() {
        let p = profile(.ssm)
        #expect(throws: ConnectionError.unsupportedConnectionType(.ssm)) { try target(p, instance()) }
    }

    @Test func stoppedInstanceFails() {
        let p = profile(.directSSH)
        #expect(throws: ConnectionError.instanceNotRunning(state: "stopped")) {
            try target(p, instance(state: "stopped"))
        }
    }

    @Test func missingInstanceFails() {
        let p = profile(.directSSH)
        #expect(throws: ConnectionError.instanceNotFound) { try target(p, nil) }
    }

    @Test func invalidUsernameIsRejectedBeforeConnecting() {
        var p = profile(.directSSH)
        p.sshUsername = "-oProxyCommand=sh"
        #expect(throws: ConnectionError.self) { try target(p, instance()) }
    }
}

@Suite("Sync document")
struct SyncDocumentTests {
    /// 동기화 문서에는 로컬 전용 필드(키 경로, AWS CLI 프로필 매핑)가 들어가지 않는다.
    @Test func syncedDocumentExcludesLocalOnlyFields() throws {
        let document = SyncedProfilesDocument(profiles: SampleData.profiles(now: fixedDate))
        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)

        for forbidden in ["sshKeyPath", "awsCLIProfileName", "terminalIdentifier", ".pem", "PRIVATE KEY", "aws_secret"] {
            #expect(!json.contains(forbidden), "\(forbidden)")
        }
        #expect(json.contains("schemaVersion"))
    }

    @Test func mockSyncRoundTrip() async throws {
        let sync = MockSyncService()
        let document = SyncedProfilesDocument(profiles: SampleData.profiles(now: fixedDate))
        try await sync.save(document, replacing: nil)
        #expect(try await sync.load().document == document)
        #expect(await sync.saveCount == 1)
    }

    @Test func mockTerminalLauncherRecordsArgumentArrays() async throws {
        let launcher = MockTerminalLauncher(installedApps: [.terminal])
        let command = TerminalCommand(executable: "/usr/bin/ssh", arguments: ["-p", "22", "ec2-user@203.0.113.9"])
        #expect(await !launcher.isAvailable(.iTerm2))
        await #expect(throws: TerminalLaunchError.appNotInstalled(.iTerm2)) {
            try await launcher.launch(command, in: .iTerm2)
        }
        try await launcher.launch(command, in: .terminal)
        #expect(await launcher.launched.map(\.command) == [command])
    }
}
