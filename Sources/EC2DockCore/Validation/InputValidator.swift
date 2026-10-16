import Foundation

public struct ValidationIssue: Equatable, Sendable {
    public enum Field: String, Sendable {
        case accountID, region, instanceID, displayName, sshUsername, sshPort
        case bastionProfile, awsCLIProfileName, sshKeyPath, terminal, connectTimeout
    }

    public let field: Field
    public let message: String
}

/// 외부 명령 인자로 쓰일 값의 형식 검증 (설계서 10.3).
/// 허용 문자만 통과시키므로 `-`로 시작하는 옵션 주입이나 shell 메타문자를 차단한다.
public enum InputValidator {
    public static func isValidAccountID(_ value: String) -> Bool {
        (try? /[0-9]{12}/.wholeMatch(in: value)) != nil
    }

    public static func isValidRegion(_ value: String) -> Bool {
        (try? /[a-z]{2}(-[a-z]+)+-[0-9]{1,2}/.wholeMatch(in: value)) != nil
    }

    /// 구형 8자리 / 신형 17자리 16진수 인스턴스 ID
    public static func isValidInstanceID(_ value: String) -> Bool {
        (try? /i-([0-9a-f]{8}|[0-9a-f]{17})/.wholeMatch(in: value)) != nil
    }

    public static func isValidSSHUsername(_ value: String) -> Bool {
        (try? /[A-Za-z_][A-Za-z0-9._-]{0,31}/.wholeMatch(in: value)) != nil
    }

    public static func isValidPort(_ value: Int) -> Bool {
        (1...65535).contains(value)
    }

    public static func isValidAWSProfileName(_ value: String) -> Bool {
        (try? /[A-Za-z0-9_][A-Za-z0-9_.+-]{0,127}/.wholeMatch(in: value)) != nil
    }

    /// 형식만 검사한다. 파일 존재와 권한 검사는 실제 SSH 연동 단계에서 수행한다.
    public static func isValidSSHKeyPath(_ value: String) -> Bool {
        guard value.hasPrefix("/") || value.hasPrefix("~/") else { return false }
        return !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    public static func isValidConnectTimeout(_ value: Int) -> Bool {
        (1...120).contains(value)
    }

    /// AWS가 반환한 IPv4/IPv6 주소인지 확인한다 (호스트 이름이나 옵션 문자열 차단).
    public static func isValidIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return inet_pton(AF_INET, value, &ipv4) == 1 || inet_pton(AF_INET6, value, &ipv6) == 1
    }

    public static func validate(_ profile: ServerProfile) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if !isValidAccountID(profile.accountID) {
            issues.append(.init(field: .accountID, message: "AWS 계정 ID는 12자리 숫자여야 합니다."))
        }
        if !isValidRegion(profile.region) {
            issues.append(.init(field: .region, message: "리전 형식이 올바르지 않습니다. 예: ap-northeast-2"))
        }
        if !isValidInstanceID(profile.instanceID) {
            issues.append(.init(field: .instanceID, message: "인스턴스 ID 형식이 올바르지 않습니다. 예: i-0123456789abcdef0"))
        }
        if profile.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(field: .displayName, message: "표시 이름을 입력하세요."))
        }
        if profile.connectionType != .ssm {
            if !isValidSSHUsername(profile.sshUsername) {
                issues.append(.init(field: .sshUsername, message: "SSH 사용자명은 영문자 또는 _로 시작하고 영문, 숫자, . _ - 만 사용할 수 있습니다."))
            }
            if !isValidPort(profile.sshPort) {
                issues.append(.init(field: .sshPort, message: "SSH 포트는 1~65535 사이여야 합니다."))
            }
        }
        if profile.connectionType == .bastionSSH {
            if profile.bastionProfileID == nil {
                issues.append(.init(field: .bastionProfile, message: "Bastion SSH 방식에는 Bastion 프로필이 필요합니다."))
            } else if profile.bastionProfileID == profile.id {
                issues.append(.init(field: .bastionProfile, message: "자기 자신을 Bastion으로 지정할 수 없습니다."))
            }
        }
        return issues
    }

    public static func validate(_ settings: LocalConnectionSettings) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if !isValidAWSProfileName(settings.awsCLIProfileName) {
            issues.append(.init(field: .awsCLIProfileName, message: "AWS CLI 프로필 이름 형식이 올바르지 않습니다."))
        }
        if let path = settings.sshKeyPath, !isValidSSHKeyPath(path) {
            issues.append(.init(field: .sshKeyPath, message: "SSH 키 경로는 / 또는 ~/ 로 시작하는 파일 경로여야 합니다."))
        }
        if TerminalApp(rawValue: settings.terminalIdentifier) == nil {
            issues.append(.init(field: .terminal, message: "지원하지 않는 터미널입니다."))
        }
        if !isValidConnectTimeout(settings.connectTimeoutSeconds) {
            issues.append(.init(field: .connectTimeout, message: "연결 타임아웃은 1~120초 사이여야 합니다."))
        }
        return issues
    }
}
