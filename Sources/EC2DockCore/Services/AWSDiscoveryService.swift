import Foundation

public struct AWSCallerIdentity: Equatable, Sendable {
    public let accountID: String
    public let arn: String

    public init(accountID: String, arn: String) {
        self.accountID = accountID
        self.arn = arn
    }
}

/// 자격 증명 만료, 권한 부족 등을 구분해 전달한다 (설계서 4.3, 11).
/// 메시지에는 비밀 값이나 원본 stderr를 포함하지 않는다.
public enum AWSDiscoveryError: Error, Equatable, Sendable {
    case cliNotFound
    case profileNotFound(String)
    case noCredentials(profile: String)
    case credentialsExpired(profile: String)
    case accessDenied(action: String)
    case networkUnavailable
    case invalidArgument(String)
    case timeout
    case invalidResponse
    /// detail은 비밀 값을 제거한 stderr 요약이다.
    case commandFailed(exitCode: Int32, detail: String)
}

extension AWSDiscoveryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cliNotFound: "AWS CLI를 찾을 수 없습니다."
        case .profileNotFound(let profile): "AWS CLI 프로필 '\(profile)'을(를) 찾을 수 없습니다."
        case .noCredentials(let profile): "'\(profile)' 프로필의 AWS 자격 증명을 찾을 수 없습니다."
        case .credentialsExpired(let profile): "'\(profile)' 프로필의 AWS 자격 증명이 만료되었습니다."
        case .accessDenied(let action): "권한이 부족합니다: \(action)"
        case .networkUnavailable: "AWS 엔드포인트에 연결할 수 없습니다."
        case .invalidArgument(let message): "잘못된 요청 값입니다: \(message)"
        case .timeout: "AWS 요청 시간이 초과되었습니다."
        case .invalidResponse: "AWS CLI 응답을 해석할 수 없습니다."
        case .commandFailed(let exitCode, let detail):
            detail.isEmpty ? "AWS CLI 실행이 실패했습니다 (종료 코드 \(exitCode))." : "AWS CLI 실행이 실패했습니다: \(detail)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .cliNotFound:
            "AWS CLI v2를 설치하세요 (예: brew install awscli). 확인한 위치: \(AWSCLILocator.wellKnownPaths.joined(separator: ", "))"
        case .profileNotFound: "~/.aws/config에 프로필이 있는지 확인하거나 Settings에서 조회할 프로필을 다시 선택하세요."
        case .noCredentials(let profile): "터미널에서 자격 증명을 설정하세요. 예: aws configure sso --profile \(profile)"
        case .credentialsExpired(let profile): "터미널에서 재인증하세요. 예: aws sso login --profile \(profile)"
        case .accessDenied(let action): "IAM 정책에 \(action) 읽기 권한이 있는지 확인하세요."
        case .networkUnavailable, .timeout: "네트워크 연결과 리전 설정을 확인한 뒤 다시 시도하세요."
        case .invalidArgument: "프로필 이름, 리전, 인스턴스 ID 설정을 확인하세요."
        case .invalidResponse: "AWS CLI v2 최신 버전을 사용 중인지 확인하세요."
        case .commandFailed: "프로필과 리전 설정을 확인하세요."
        }
    }
}

/// AWS 인스턴스 조회 계층. Phase 2에서 AWS CLI subprocess 구현으로 대체한다.
/// 읽기 전용 호출만 정의한다 (EC2 변경 작업은 MVP 범위 밖).
public protocol AWSDiscoveryService: Sendable {
    func listProfiles() async throws -> [String]
    func callerIdentity(profile: String) async throws -> AWSCallerIdentity
    func describeInstances(profile: String, region: String) async throws -> [EC2Instance]
    /// 서버 한 대 재조회용. 인스턴스가 없으면 nil.
    func describeInstance(profile: String, region: String, instanceID: String) async throws -> EC2Instance?
    /// 터미널에서 실행할 로그인 명령. 앱은 자격 증명을 다루지 않고 AWS CLI가 직접 로그인한다.
    func loginCommand(profile: String) async throws -> TerminalCommand
    /// 새 계정(프로필)을 추가하는 대화형 명령
    func addAccountCommand(profile: String, method: AWSAccountSetupMethod) async throws -> TerminalCommand
}

/// 앱에서 AWS 계정을 추가하는 방법. 장기 액세스 키(`aws configure`)는 제공하지 않는다.
public enum AWSAccountSetupMethod: String, CaseIterable, Identifiable, Sendable {
    /// AWS 콘솔 로그인 정보로 임시 자격 증명 (AWS CLI 2.32.0 이상)
    case consoleLogin
    /// IAM Identity Center(SSO)
    case identityCenter

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .consoleLogin: "AWS 콘솔 로그인 (aws login)"
        case .identityCenter: "IAM Identity Center / SSO (aws configure sso)"
        }
    }

    public var arguments: [String] {
        switch self {
        case .consoleLogin: ["login"]
        case .identityCenter: ["configure", "sso"]
        }
    }
}

extension AWSDiscoveryError {
    /// 로그인하면 해결되는 오류라면 해당 AWS CLI 프로필
    public var loginProfile: String? {
        switch self {
        case .credentialsExpired(let profile), .noCredentials(let profile): profile.isEmpty ? nil : profile
        default: nil
        }
    }
}
