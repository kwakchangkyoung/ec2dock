import Foundation

/// AWS CLI subprocess 기반 조회 (설계서 4.1, 7). 읽기 전용 API만 호출한다:
/// `configure list-profiles`, `sts get-caller-identity`, `ec2 describe-instances`.
/// 자격 증명은 앱이 다루지 않고 기존 AWS CLI 인증 체계를 그대로 사용한다.
public struct AWSCLIDiscoveryService: AWSDiscoveryService {
    private let runner: any CommandRunner
    private let locate: @Sendable () -> URL?
    private let timeout: Duration

    public init(
        runner: any CommandRunner = ProcessCommandRunner(),
        locate: @escaping @Sendable () -> URL? = { AWSCLILocator.locate() },
        timeout: Duration = .seconds(30)
    ) {
        self.runner = runner
        self.locate = locate
        self.timeout = timeout
    }

    public func listProfiles() async throws -> [String] {
        let output = try await run(["configure", "list-profiles"], profile: nil, action: "configure list-profiles")
        return String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(InputValidator.isValidAWSProfileName)
            .sorted()
    }

    public func callerIdentity(profile: String) async throws -> AWSCallerIdentity {
        try validate(profile: profile)
        let output = try await run(
            ["sts", "get-caller-identity", "--profile", profile, "--output", "json"],
            profile: profile, action: "sts:GetCallerIdentity")
        return try AWSCLIResponseParser.callerIdentity(from: output)
    }

    public func describeInstances(profile: String, region: String) async throws -> [EC2Instance] {
        try validate(profile: profile, region: region)
        let output = try await run(
            ["ec2", "describe-instances", "--profile", profile, "--region", region, "--output", "json"],
            profile: profile, action: "ec2:DescribeInstances")
        return try AWSCLIResponseParser.instances(from: output, region: region, fetchedAt: Date())
    }

    public func describeInstance(profile: String, region: String, instanceID: String) async throws -> EC2Instance? {
        try validate(profile: profile, region: region)
        guard InputValidator.isValidInstanceID(instanceID) else { throw AWSDiscoveryError.invalidArgument("인스턴스 ID") }
        do {
            let output = try await run(
                ["ec2", "describe-instances", "--profile", profile, "--region", region,
                 "--instance-ids", instanceID, "--output", "json"],
                profile: profile, action: "ec2:DescribeInstances")
            return try AWSCLIResponseParser.instances(from: output, region: region, fetchedAt: Date())
                .first { $0.instanceID == instanceID }
        } catch AWSCLIInternalError.instanceNotFound {
            return nil
        }
    }

    /// SSO 설정(sso_session/sso_start_url)이 있으면 `aws sso login`, 없으면 `aws login`.
    /// 설정 값은 로컬 파일에서만 읽으며 네트워크를 쓰지 않는다.
    public func loginCommand(profile: String) async throws -> TerminalCommand {
        try validate(profile: profile)
        guard let executable = locate() else { throw AWSDiscoveryError.cliNotFound }
        var usesSSO = false
        for key in ["sso_session", "sso_start_url"] where !usesSSO {
            usesSSO = await hasConfigValue(key, profile: profile)
        }
        let arguments = usesSSO ? ["sso", "login", "--profile", profile] : ["login", "--profile", profile]
        return TerminalCommand(executable: executable.path, arguments: arguments)
    }

    public func addAccountCommand(profile: String, method: AWSAccountSetupMethod) async throws -> TerminalCommand {
        try validate(profile: profile)
        guard let executable = locate() else { throw AWSDiscoveryError.cliNotFound }
        return TerminalCommand(executable: executable.path, arguments: method.arguments + ["--profile", profile])
    }

    /// `aws configure get`은 값이 없으면 실패 코드로 끝난다.
    private func hasConfigValue(_ key: String, profile: String) async -> Bool {
        guard let output = try? await run(["configure", "get", key, "--profile", profile], profile: profile, action: "configure get") else {
            return false
        }
        return !String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Private

    private func validate(profile: String, region: String? = nil) throws {
        guard InputValidator.isValidAWSProfileName(profile) else { throw AWSDiscoveryError.invalidArgument("프로필 이름") }
        if let region, !InputValidator.isValidRegion(region) { throw AWSDiscoveryError.invalidArgument("리전") }
    }

    private func run(_ arguments: [String], profile: String?, action: String) async throws -> Data {
        guard let executable = locate() else { throw AWSDiscoveryError.cliNotFound }

        let result: CommandResult
        do {
            result = try await runner.run(
                executable,
                arguments: arguments + ["--no-cli-pager"],
                environment: Self.environment(cliDirectory: executable.deletingLastPathComponent().path),
                timeout: timeout)
        } catch CommandRunnerError.timedOut {
            throw AWSDiscoveryError.timeout
        } catch CommandRunnerError.launchFailed {
            throw AWSDiscoveryError.cliNotFound
        }

        guard result.exitCode == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            if AWSCLIErrorMapper.isInstanceNotFound(stderr) { throw AWSCLIInternalError.instanceNotFound }
            throw AWSCLIErrorMapper.map(stderr: stderr, exitCode: result.exitCode, profile: profile ?? "", action: action)
        }
        return result.stdout
    }

    /// 상속 환경 변수에 pager 비활성화만 더한다. 자격 증명 값을 주입하지 않는다.
    static func environment(cliDirectory: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["AWS_PAGER"] = ""
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !path.split(separator: ":").contains(Substring(cliDirectory)) {
            environment["PATH"] = "\(cliDirectory):\(path)"
        }
        return environment
    }
}

enum AWSCLIInternalError: Error {
    case instanceNotFound
}

// MARK: - 응답 파싱

enum AWSCLIResponseParser {
    private struct CallerIdentityResponse: Decodable {
        let Account: String
        let Arn: String
    }

    private struct DescribeInstancesResponse: Decodable {
        struct Reservation: Decodable {
            /// 인스턴스를 소유한 AWS 계정 ID
            let OwnerId: String
            let Instances: [Instance]?
        }

        struct Instance: Decodable {
            struct State: Decodable { let Name: String }
            struct Placement: Decodable { let AvailabilityZone: String? }
            struct Tag: Decodable { let Key: String; let Value: String? }

            let InstanceId: String
            let State: State
            let PublicIpAddress: String?
            let PrivateIpAddress: String?
            let InstanceType: String?
            let VpcId: String?
            let Placement: Placement?
            let Tags: [Tag]?
        }

        let Reservations: [Reservation]?
    }

    static func callerIdentity(from data: Data) throws -> AWSCallerIdentity {
        guard let response = try? JSONDecoder().decode(CallerIdentityResponse.self, from: data),
              InputValidator.isValidAccountID(response.Account) else {
            throw AWSDiscoveryError.invalidResponse
        }
        return AWSCallerIdentity(accountID: response.Account, arn: response.Arn)
    }

    static func instances(from data: Data, region: String, fetchedAt: Date) throws -> [EC2Instance] {
        guard let response = try? JSONDecoder().decode(DescribeInstancesResponse.self, from: data) else {
            throw AWSDiscoveryError.invalidResponse
        }
        return try (response.Reservations ?? []).flatMap { reservation in
            guard InputValidator.isValidAccountID(reservation.OwnerId) else { throw AWSDiscoveryError.invalidResponse }
            return (reservation.Instances ?? [])
                .filter { InputValidator.isValidInstanceID($0.InstanceId) }
                .map { instance in
                let tags = Dictionary((instance.Tags ?? []).map { ($0.Key, $0.Value ?? "") }, uniquingKeysWith: { $1 })
                return EC2Instance(
                    accountID: reservation.OwnerId,
                    region: region,
                    instanceID: instance.InstanceId,
                    state: instance.State.Name,
                    publicIPAddress: instance.PublicIpAddress,
                    privateIPAddress: instance.PrivateIpAddress,
                    availabilityZone: instance.Placement?.AvailabilityZone,
                    instanceType: instance.InstanceType,
                    vpcID: instance.VpcId,
                    tags: tags,
                    lastFetchedAt: fetchedAt)
                }
        }
    }
}

// MARK: - 오류 분류

/// stderr를 사용자에게 그대로 보여주지 않고 원인별로 분류한다 (자격 증명 만료와 권한 부족 구분).
enum AWSCLIErrorMapper {
    static func isInstanceNotFound(_ stderr: String) -> Bool {
        stderr.contains("InvalidInstanceID.NotFound")
    }

    static func map(stderr: String, exitCode: Int32, profile: String, action: String) -> AWSDiscoveryError {
        let text = stderr.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0.lowercased()) } }

        if has("could not be found") && has("profile") {
            return .profileNotFound(profile)
        }
        if has("ExpiredToken", "token has expired", "session has expired", "Error loading SSO Token",
               "RequestExpired", "refresh failed") {
            return .credentialsExpired(profile: profile)
        }
        if has("Unable to locate credentials", "InvalidClientTokenId", "partial credentials") {
            return .noCredentials(profile: profile)
        }
        if has("UnauthorizedOperation", "AccessDenied", "not authorized", "AuthFailure") {
            return .accessDenied(action: action)
        }
        if has("Could not connect to the endpoint", "Connect timeout", "Name or service not known",
               "nodename nor servname") {
            return .networkUnavailable
        }
        return .commandFailed(exitCode: exitCode, detail: summary(of: stderr))
    }

    /// 첫 번째 의미 있는 줄만 남기고 비밀 값으로 보이는 문자열을 가린다.
    static func summary(of stderr: String) -> String {
        let line = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(SecretRedactor.redact(line).prefix(200))
    }
}

/// 외부 명령 출력에서 비밀 값으로 보이는 패턴을 제거한다 (설계서 10.3).
public enum SecretRedactor {
    public static func redact(_ text: String) -> String {
        var result = text
        // Access key ID (장기/임시)
        result.replace(/(AKIA|ASIA|AROA|AIDA)[A-Z0-9]{16}/, with: "[REDACTED]")
        // key=value 형태의 비밀 값
        result.replace(/(?i)(aws_secret_access_key|aws_session_token|secretaccesskey|sessiontoken|password)(["']?\s*[:=]\s*)\S+/) {
            "\($0.output.1)\($0.output.2)[REDACTED]"
        }
        // 40자 이상 base64 형태 토큰 (시크릿 키, 세션 토큰)
        result.replace(/[A-Za-z0-9\/+=]{40,}/, with: "[REDACTED]")
        return result
    }
}
