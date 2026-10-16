import Foundation
import Testing
@testable import EC2DockCore

/// 인자 배열을 기록하고 미리 정한 결과를 돌려주는 실행기. 실제 AWS CLI를 실행하지 않는다.
actor FakeRunner: CommandRunner {
    private(set) var calls: [[String]] = []
    private(set) var environments: [[String: String]] = []
    private var responses: [(prefix: [String], result: Result<CommandResult, CommandRunnerError>)] = []

    func respond(to prefix: [String], stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        responses.append((prefix, .success(CommandResult(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8)))))
    }

    func fail(_ prefix: [String], with error: CommandRunnerError) {
        responses.append((prefix, .failure(error)))
    }

    func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> CommandResult {
        calls.append(arguments)
        environments.append(environment)
        guard let match = responses.last(where: { arguments.starts(with: $0.prefix) }) else {
            return CommandResult(exitCode: 255, stdout: Data(), stderr: Data("unexpected call".utf8))
        }
        return try match.result.get()
    }
}

private let awsURL = URL(fileURLWithPath: "/opt/homebrew/bin/aws")

private let describeFixture = """
{
  "Reservations": [
    {
      "OwnerId": "123456789012",
      "Instances": [
        {
          "InstanceId": "i-0123456789abcdef0",
          "InstanceType": "t3.micro",
          "VpcId": "vpc-0123456789abcdef0",
          "State": { "Code": 16, "Name": "running" },
          "PublicIpAddress": "203.0.113.50",
          "PrivateIpAddress": "10.0.1.5",
          "Placement": { "AvailabilityZone": "ap-northeast-2a", "Tenancy": "default" },
          "Tags": [ { "Key": "Name", "Value": "web-01" }, { "Key": "Environment", "Value": "Production" } ]
        }
      ]
    },
    {
      "OwnerId": "123456789012",
      "Instances": [
        {
          "InstanceId": "i-0fedcba9876543210",
          "State": { "Code": 80, "Name": "stopped" },
          "PrivateIpAddress": "10.0.2.9",
          "Placement": { "AvailabilityZone": "ap-northeast-2c" }
        }
      ]
    }
  ]
}
"""

@Suite("AWSCLIDiscoveryService")
struct AWSCLIDiscoveryServiceTests {
    let runner = FakeRunner()

    private func service(cliFound: Bool = true) -> AWSCLIDiscoveryService {
        AWSCLIDiscoveryService(runner: runner, locate: { cliFound ? awsURL : nil }, timeout: .seconds(5))
    }

    @Test func listProfilesParsesLinesAndDropsInvalidNames() async throws {
        await runner.respond(to: ["configure", "list-profiles"], stdout: "default\nacme-prod\n\n-bad\nacme dev\n")
        #expect(try await service().listProfiles() == ["acme-prod", "default"])
    }

    @Test func callerIdentityUsesArgumentArray() async throws {
        await runner.respond(to: ["sts"], stdout: #"{"UserId":"AIDAEXAMPLE","Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/me"}"#)
        let identity = try await service().callerIdentity(profile: "acme-prod")

        #expect(identity.accountID == "123456789012")
        #expect(await runner.calls == [["sts", "get-caller-identity", "--profile", "acme-prod", "--output", "json", "--no-cli-pager"]])
        #expect(await runner.environments.first?["AWS_PAGER"] == "")
    }

    @Test func describeInstancesParsesFixture() async throws {
        await runner.respond(to: ["ec2", "describe-instances"], stdout: describeFixture)
        let instances = try await service().describeInstances(profile: "acme-prod", region: "ap-northeast-2")

        #expect(await runner.calls == [[
            "ec2", "describe-instances", "--profile", "acme-prod", "--region", "ap-northeast-2",
            "--output", "json", "--no-cli-pager",
        ]])
        #expect(instances.count == 2)

        let web = try #require(instances.first { $0.instanceID == "i-0123456789abcdef0" })
        #expect(web.accountID == "123456789012")
        #expect(web.region == "ap-northeast-2")
        #expect(web.name == "web-01")
        #expect(web.environmentTag == "Production")
        #expect(web.state == "running")
        #expect(web.publicIPAddress == "203.0.113.50")
        #expect(web.availabilityZone == "ap-northeast-2a")
        #expect(web.vpcID == "vpc-0123456789abcdef0")

        let stopped = try #require(instances.first { $0.instanceID == "i-0fedcba9876543210" })
        #expect(stopped.publicIPAddress == nil)
        #expect(stopped.name == nil)
        #expect(stopped.tags.isEmpty)
        #expect(!stopped.isRunning)
    }

    @Test func emptyReservationsReturnEmptyList() async throws {
        await runner.respond(to: ["ec2"], stdout: #"{"Reservations": []}"#)
        #expect(try await service().describeInstances(profile: "p", region: "us-east-1").isEmpty)
    }

    @Test func describeSingleInstanceUsesInstanceIDs() async throws {
        await runner.respond(to: ["ec2"], stdout: describeFixture)
        let instance = try await service().describeInstance(profile: "p", region: "ap-northeast-2", instanceID: "i-0123456789abcdef0")
        #expect(instance?.publicIPAddress == "203.0.113.50")
        #expect(await runner.calls.first?.contains("--instance-ids") == true)
    }

    @Test func missingInstanceReturnsNil() async throws {
        await runner.respond(to: ["ec2"], stderr: "An error occurred (InvalidInstanceID.NotFound) when calling the DescribeInstances operation: The instance ID 'i-0123456789abcdef0' does not exist", exitCode: 254)
        #expect(try await service().describeInstance(profile: "p", region: "ap-northeast-2", instanceID: "i-0123456789abcdef0") == nil)
    }

    @Test func cliNotFoundDoesNotRunAnything() async {
        await #expect(throws: AWSDiscoveryError.cliNotFound) {
            try await service(cliFound: false).listProfiles()
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test(arguments: ["-x", "a b", "p;id", "--debug"])
    func invalidProfileIsRejectedBeforeRunning(_ profile: String) async {
        await #expect(throws: AWSDiscoveryError.invalidArgument("프로필 이름")) {
            try await service().describeInstances(profile: profile, region: "us-east-1")
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test func invalidRegionAndInstanceIDAreRejected() async {
        await #expect(throws: AWSDiscoveryError.invalidArgument("리전")) {
            try await service().describeInstances(profile: "p", region: "us-east-1 --endpoint-url x")
        }
        await #expect(throws: AWSDiscoveryError.invalidArgument("인스턴스 ID")) {
            try await service().describeInstance(profile: "p", region: "us-east-1", instanceID: "i-1;id")
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test func timeoutIsMapped() async {
        await runner.fail(["sts"], with: .timedOut)
        await #expect(throws: AWSDiscoveryError.timeout) {
            try await service().callerIdentity(profile: "p")
        }
    }

    @Test func malformedJSONIsInvalidResponse() async {
        await runner.respond(to: ["ec2"], stdout: "not json")
        await #expect(throws: AWSDiscoveryError.invalidResponse) {
            try await service().describeInstances(profile: "p", region: "us-east-1")
        }
    }

    @Test func nonzeroExitIsClassified() async {
        await runner.respond(to: ["sts"], stderr: "\nUnable to locate credentials. You can configure credentials by running \"aws configure\".\n", exitCode: 253)
        await #expect(throws: AWSDiscoveryError.noCredentials(profile: "p")) {
            try await service().callerIdentity(profile: "p")
        }
    }
}

@Suite("AWSCLIErrorMapper")
struct AWSCLIErrorMapperTests {
    private func map(_ stderr: String) -> AWSDiscoveryError {
        AWSCLIErrorMapper.map(stderr: stderr, exitCode: 255, profile: "acme", action: "ec2:DescribeInstances")
    }

    @Test func classifiesKnownErrors() {
        #expect(map("The config profile (acme) could not be found") == .profileNotFound("acme"))
        #expect(map("Error when retrieving token from sso: Token has expired and refresh failed") == .credentialsExpired(profile: "acme"))
        #expect(map("An error occurred (ExpiredToken) when calling the GetCallerIdentity operation") == .credentialsExpired(profile: "acme"))
        #expect(map("An error occurred (UnauthorizedOperation) when calling the DescribeInstances operation: You are not authorized") == .accessDenied(action: "ec2:DescribeInstances"))
        #expect(map("An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation") == .noCredentials(profile: "acme"))
        #expect(map("Could not connect to the endpoint URL: \"https://ec2.ap-northeast-2.amazonaws.com/\"") == .networkUnavailable)
    }

    @Test func unknownErrorKeepsRedactedSummaryOnly() {
        let error = map("\nboom AKIAIOSFODNN7EXAMPLE aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\nsecond line")
        guard case .commandFailed(255, let detail) = error else {
            Issue.record("unexpected \(error)")
            return
        }
        #expect(!detail.contains("AKIAIOSFODNN7EXAMPLE"))
        #expect(!detail.contains("wJalrXUtnFEMI"))
        #expect(!detail.contains("second line"))
        #expect(detail.contains("boom"))
    }
}

@Suite("SecretRedactor")
struct SecretRedactorTests {
    @Test func redactsAccessKeysAndSecrets() {
        let text = "id=ASIAIOSFODNN7EXAMPLE token: \"FwoGZXIvYXdzEJr//////////wEaDExampleSessionTokenValue1234567890\" password=hunter2"
        let redacted = SecretRedactor.redact(text)
        #expect(!redacted.contains("ASIAIOSFODNN7EXAMPLE"))
        #expect(!redacted.contains("FwoGZXIvYXdzEJr"))
        #expect(!redacted.contains("hunter2"))
    }

    @Test func keepsOrdinaryText() {
        let text = "An error occurred (Throttling) when calling the DescribeInstances operation: Rate exceeded"
        #expect(SecretRedactor.redact(text) == text)
    }
}

@Suite("AWSCLILocator")
struct AWSCLILocatorTests {
    @Test func prefersWellKnownPaths() {
        let url = AWSCLILocator.locate(environment: ["PATH": "/custom/bin"]) { $0 == "/usr/local/bin/aws" || $0 == "/custom/bin/aws" }
        #expect(url?.path == "/usr/local/bin/aws")
    }

    @Test func searchesAbsolutePathEntriesOnly() {
        #expect(AWSCLILocator.locate(environment: ["PATH": ".:bin:/custom/bin"]) { $0 == "/custom/bin/aws" }?.path == "/custom/bin/aws")
        #expect(AWSCLILocator.locate(environment: ["PATH": ".:bin"]) { $0 == "./aws" || $0 == "bin/aws" } == nil)
    }

    @Test func returnsNilWhenMissing() {
        #expect(AWSCLILocator.locate(environment: [:]) { _ in false } == nil)
    }
}
