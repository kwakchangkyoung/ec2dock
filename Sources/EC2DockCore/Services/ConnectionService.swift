import Foundation

/// 사전 검증을 마친 접속 대상 (캐시된 인스턴스 정보 기준).
public struct ConnectionTarget: Equatable, Sendable {
    public let profile: ServerProfile
    public let instance: EC2Instance
    /// Direct SSH: 공인 IP, Bastion SSH: 사설 IP, SSM: nil (인스턴스 ID로 접속)
    public let address: String?
    public let settings: LocalConnectionSettings
    /// Bastion SSH일 때 경유할 서버
    public let bastion: BastionHop?

    init(profile: ServerProfile, instance: EC2Instance, address: String?, settings: LocalConnectionSettings, bastion: BastionHop? = nil) {
        self.profile = profile
        self.instance = instance
        self.address = address
        self.settings = settings
        self.bastion = bastion
    }
}

/// 검증을 마친 Bastion 구간. 사용자명·포트·키는 Bastion 서버 자신의 설정을 쓴다 (설계서 8.2).
public struct BastionHop: Equatable, Sendable {
    public let profile: ServerProfile
    public let instance: EC2Instance
    /// Bastion 공인 IP
    public let address: String
    public let settings: LocalConnectionSettings
}

/// 사전 검증에 넘기는 Bastion 서버 정보 (캐시 기준)
public struct BastionInput: Sendable {
    public let profile: ServerProfile
    public let instance: EC2Instance?
    public let settings: LocalConnectionSettings

    public init(profile: ServerProfile, instance: EC2Instance?, settings: LocalConnectionSettings) {
        self.profile = profile
        self.instance = instance
        self.settings = settings
    }
}

public enum ConnectionError: Error, Equatable, Sendable {
    case instanceNotFound
    case noCachedInstance
    case instanceNotRunning(state: String)
    case noPublicIP
    case noPrivateIP
    case bastionNotConfigured
    case bastionNotFound
    case bastionNotRunning(state: String)
    case bastionNoPublicIP
    case accountMismatch(expected: String, actual: String)
    case invalidConfiguration([String])
    case productionConfirmationRequired
    case discoveryFailed(AWSDiscoveryError)
    case unsupportedConnectionType(ConnectionType)
    case keyFileNotFound(String)
    case keyFilePermissionsTooOpen(String)
    case terminalUnavailable(TerminalApp)
    case automationPermissionDenied(TerminalApp)
    case launchFailed(String)
}

extension ConnectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .instanceNotFound: "인스턴스를 찾을 수 없습니다."
        case .noCachedInstance: "이 Mac에 조회된 인스턴스 정보가 없습니다."
        case .instanceNotRunning(let state): "인스턴스가 실행 중이 아닙니다 (현재 상태: \(state))."
        case .noPublicIP: "공인 IP가 없어 Direct SSH로 접속할 수 없습니다."
        case .noPrivateIP: "사설 IP를 확인할 수 없습니다."
        case .bastionNotConfigured: "Bastion 프로필이 지정되지 않았습니다."
        case .bastionNotFound: "지정한 Bastion 서버를 찾을 수 없습니다."
        case .bastionNotRunning(let state): "Bastion 서버가 실행 중이 아닙니다 (현재 상태: \(state))."
        case .bastionNoPublicIP: "Bastion 서버에 공인 IP가 없습니다."
        case .accountMismatch(let expected, let actual): "AWS 계정이 일치하지 않습니다 (서버: \(expected), 현재 프로필: \(actual))."
        case .invalidConfiguration(let messages): messages.joined(separator: "\n")
        case .productionConfirmationRequired: "Production 서버 접속 확인이 필요합니다."
        case .discoveryFailed(let error): error.errorDescription
        case .unsupportedConnectionType(let type): "\(type.displayName) 접속은 아직 지원하지 않습니다."
        case .keyFileNotFound(let path): "SSH 키 파일을 찾을 수 없습니다: \(path)"
        case .keyFilePermissionsTooOpen(let path): "SSH 키 파일 권한이 너무 넓습니다: \(path)"
        case .terminalUnavailable(let app): "\(app.displayName)을(를) 찾을 수 없습니다."
        case .automationPermissionDenied(let app): "\(app.displayName)을(를) 제어할 권한이 없습니다."
        case .launchFailed(let message): "접속을 시작하지 못했습니다: \(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .instanceNotFound: "인스턴스가 종료되었는지, 계정과 리전 설정이 맞는지 확인하세요."
        case .noCachedInstance: "\"다시 조회\" 또는 목록의 새로고침으로 AWS에서 정보를 가져오세요. IP·상태는 iCloud로 동기화되지 않습니다."
        case .instanceNotRunning: "인스턴스를 시작한 뒤 \"다시 조회\"로 상태를 갱신하세요."
        case .noPublicIP: "접속 설정에서 Bastion SSH 또는 SSM 방식으로 변경하세요."
        case .noPrivateIP: "인스턴스의 네트워크 구성을 확인하세요."
        case .bastionNotConfigured: "접속 설정에서 Bastion 프로필을 선택하세요."
        case .bastionNotFound: "접속 설정에서 같은 계정의 Bastion 서버를 다시 선택하세요."
        case .bastionNotRunning: "Bastion 서버를 시작한 뒤 Bastion 서버 정보에서 \"다시 조회\"를 누르세요."
        case .bastionNoPublicIP: "공인 IP가 있는 서버를 Bastion으로 선택하거나, Bastion 서버 정보에서 \"다시 조회\"를 누르세요."
        case .accountMismatch: "이 서버에 매핑된 AWS CLI 프로필을 확인하세요."
        case .invalidConfiguration: "접속 설정을 수정하세요."
        case .productionConfirmationRequired: nil
        case .discoveryFailed(let error): error.recoverySuggestion
        case .unsupportedConnectionType: "SSM 접속은 다음 단계에서 지원합니다. 지금은 Direct SSH 또는 Bastion SSH를 사용하세요."
        case .keyFileNotFound: "접속 설정에서 이 Mac의 SSH 키 파일 경로를 지정하세요."
        case .keyFilePermissionsTooOpen(let path): "OpenSSH는 다른 사용자가 읽을 수 있는 키를 거부합니다. 터미널에서 chmod 600 \(path) 을(를) 실행하세요."
        case .terminalUnavailable: "Terminal로 열거나 명령을 복사해 직접 실행하세요."
        case .automationPermissionDenied(let app):
            "시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 EC2Dock(또는 EC2Dock을 실행한 터미널 앱)이 \(app.displayName)을(를) 제어하도록 허용하세요."
        case .launchFailed: "Terminal로 열거나 명령을 복사해 직접 실행하세요."
        }
    }
}

extension ConnectionError {
    /// 로그인하면 해결되는 오류라면 해당 AWS CLI 프로필
    public var loginProfile: String? {
        if case .discoveryFailed(let error) = self { return error.loginProfile }
        return nil
    }
}

/// 접속 방식별 사전 검증 (FR-006, FR-010). 캐시가 아닌 재조회 결과를 넣어 호출한다.
public enum ConnectionPreflight {
    public static func makeTarget(
        profile: ServerProfile,
        instance: EC2Instance?,
        settings: LocalConnectionSettings,
        bastion: BastionInput? = nil
    ) throws(ConnectionError) -> ConnectionTarget {
        let issues = InputValidator.validate(profile) + InputValidator.validate(settings)
        guard issues.isEmpty else { throw .invalidConfiguration(issues.map(\.message)) }

        guard let instance else { throw .instanceNotFound }
        guard instance.isRunning else { throw .instanceNotRunning(state: instance.state) }

        switch profile.connectionType {
        case .directSSH:
            guard let ip = instance.publicIPAddress else { throw .noPublicIP }
            return ConnectionTarget(profile: profile, instance: instance, address: ip, settings: settings)
        case .bastionSSH:
            guard profile.bastionProfileID != nil else { throw .bastionNotConfigured }
            guard let ip = instance.privateIPAddress else { throw .noPrivateIP }
            let hop = try bastionHop(for: profile, bastion: bastion)
            return ConnectionTarget(profile: profile, instance: instance, address: ip, settings: settings, bastion: hop)
        case .ssm:
            throw .unsupportedConnectionType(.ssm)
        }
    }

    /// Bastion은 같은 계정의 다른 서버여야 하고, 실행 중이며 공인 IP가 있어야 한다.
    private static func bastionHop(for profile: ServerProfile, bastion: BastionInput?) throws(ConnectionError) -> BastionHop {
        guard let bastion, bastion.profile.id == profile.bastionProfileID,
              bastion.profile.id != profile.id, bastion.profile.accountID == profile.accountID else {
            throw .bastionNotFound
        }
        var messages: [String] = []
        if !InputValidator.isValidSSHUsername(bastion.profile.sshUsername) {
            messages.append("Bastion 서버의 SSH 사용자명 형식이 올바르지 않습니다.")
        }
        if !InputValidator.isValidPort(bastion.profile.sshPort) {
            messages.append("Bastion 서버의 SSH 포트가 올바르지 않습니다.")
        }
        messages += InputValidator.validate(bastion.settings).map { "Bastion 서버: \($0.message)" }
        guard messages.isEmpty else { throw .invalidConfiguration(messages) }

        guard let instance = bastion.instance else { throw .bastionNotRunning(state: "조회 정보 없음") }
        guard instance.isRunning else { throw .bastionNotRunning(state: instance.state) }
        guard let ip = instance.publicIPAddress, InputValidator.isValidIPAddress(ip) else { throw .bastionNoPublicIP }
        return BastionHop(profile: bastion.profile, instance: instance, address: ip, settings: bastion.settings)
    }
}

/// 앱 안 터미널 창에서 실행할 세션. 명령은 검증된 인자 배열이다.
public struct EmbeddedTerminalSession: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 서버 접속. `ServerProfile.id` (다시 연결, 목록 표시에 사용)
        case ssh(profileID: String)
        /// AWS CLI 로그인. 성공하면 원래 하려던 조회를 다시 시도한다.
        case awsLogin(awsProfile: String)
    }

    public let id: UUID
    public let kind: Kind
    public let title: String
    /// 예: "ec2-user@203.0.113.25"
    public let destination: String
    public let isProduction: Bool
    public let command: TerminalCommand

    public init(id: UUID = UUID(), kind: Kind, title: String, destination: String, isProduction: Bool, command: TerminalCommand) {
        self.id = id
        self.kind = kind
        self.title = title
        self.destination = destination
        self.isProduction = isProduction
        self.command = command
    }

    /// ssh 세션이면 접속한 서버 ID
    public var profileID: String? {
        if case .ssh(let profileID) = kind { return profileID }
        return nil
    }
}

public enum ConnectionOutcome: Equatable, Sendable {
    /// 외부 터미널(iTerm2/Terminal)에서 실행을 시작했다.
    case external(message: String)
    /// UI가 내장 터미널 창을 열어 실행해야 한다.
    case embedded(EmbeddedTerminalSession)
}

/// Direct / Bastion / SSM 접속 실행 계층.
public protocol ConnectionService: Sendable {
    func connect(_ target: ConnectionTarget, in terminal: TerminalApp) async throws -> ConnectionOutcome
}
