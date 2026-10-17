import Foundation

/// Direct SSH / Bastion SSH 명령을 인자 배열로 구성한다 (설계서 8.1, 8.2, 8.5).
/// - 호스트 키 검증 옵션(StrictHostKeyChecking 등)은 건드리지 않고 사용자의 OpenSSH 설정을 따른다.
/// - `HostKeyAlias`를 인스턴스 ID로 지정해 known_hosts를 IP가 아닌 인스턴스 기준으로 기록한다.
///   IP가 바뀌어도 같은 인스턴스는 같은 키로 검증되고, 재할당된 IP를 다른 서버로 착각하지 않는다.
/// - 키 파일은 존재 여부와 권한만 확인하며 내용은 읽지 않는다.
public struct SSHCommandBuilder: Sendable {
    public enum KeyFileStatus: Sendable {
        case ok
        case missing
        case tooOpen
    }

    public static let sshPath = "/usr/bin/ssh"

    private let keyFileStatus: @Sendable (String) -> KeyFileStatus

    public init(keyFileStatus: @escaping @Sendable (String) -> KeyFileStatus = SSHCommandBuilder.checkKeyFile) {
        self.keyFileStatus = keyFileStatus
    }

    public func command(for target: ConnectionTarget) throws(ConnectionError) -> TerminalCommand {
        let profile = target.profile
        let settings = target.settings

        // 사전 검증을 통과했더라도 명령 구성 직전에 한 번 더 확인한다.
        let issues = InputValidator.validate(profile) + InputValidator.validate(settings)
        guard issues.isEmpty else { throw .invalidConfiguration(issues.map(\.message)) }

        switch profile.connectionType {
        case .directSSH:
            guard let host = target.address, InputValidator.isValidIPAddress(host) else { throw .noPublicIP }
            return TerminalCommand(executable: Self.sshPath, arguments: try hopArguments(
                instanceID: profile.instanceID, username: profile.sshUsername, host: host, port: profile.sshPort,
                settings: settings))

        case .bastionSSH:
            guard let host = target.address, InputValidator.isValidIPAddress(host) else { throw .noPrivateIP }
            guard let bastion = target.bastion else { throw .bastionNotConfigured }
            guard InputValidator.isValidIPAddress(bastion.address) else { throw .bastionNoPublicIP }
            guard InputValidator.isValidSSHUsername(bastion.profile.sshUsername), InputValidator.isValidPort(bastion.profile.sshPort),
                  InputValidator.isValidInstanceID(bastion.profile.instanceID), InputValidator.validate(bastion.settings).isEmpty else {
                throw .invalidConfiguration(["Bastion 서버의 접속 설정을 확인하세요."])
            }

            // Bastion 구간: 같은 ssh를 -W로 실행해 대상 서버까지의 통로만 연다.
            // 대상 주소를 직접 넣어 %h/%p 토큰 해석에 의존하지 않는다.
            let forward = host.contains(":") ? "[\(host)]:\(profile.sshPort)" : "\(host):\(profile.sshPort)"
            var jump = [Self.sshPath] + (try keyArguments(bastion.settings))
            jump += [
                "-o", "ConnectTimeout=\(bastion.settings.connectTimeoutSeconds)",
                "-o", "HostKeyAlias=\(bastion.profile.instanceID)",
                "-p", String(bastion.profile.sshPort),
                "-W", forward,
                "--", "\(bastion.profile.sshUsername)@\(bastion.address)",
            ]
            let proxyCommand = Self.proxyCommandValue(jump)

            var arguments = try hopArguments(instanceID: profile.instanceID, username: profile.sshUsername, host: host,
                                             port: profile.sshPort, settings: settings)
            // 대상 구간 옵션 뒤, "--" 앞에 ProxyCommand를 넣는다.
            let separator = arguments.firstIndex(of: "--") ?? arguments.endIndex
            arguments.insert(contentsOf: ["-o", "ProxyCommand=\(proxyCommand)"], at: separator)
            return TerminalCommand(executable: Self.sshPath, arguments: arguments)

        case .ssm:
            throw .unsupportedConnectionType(.ssm)
        }
    }

    /// 한 구간의 ssh 인자: 키, 타임아웃, 인스턴스 ID 기준 호스트 키 검증, 포트, 목적지
    private func hopArguments(instanceID: String, username: String, host: String, port: Int,
                              settings: LocalConnectionSettings) throws(ConnectionError) -> [String] {
        try keyArguments(settings) + [
            "-o", "ConnectTimeout=\(settings.connectTimeoutSeconds)",
            "-o", "HostKeyAlias=\(instanceID)",
            "-p", String(port),
            "--",
            "\(username)@\(host)",
        ]
    }

    private func keyArguments(_ settings: LocalConnectionSettings) throws(ConnectionError) -> [String] {
        guard let keyPath = settings.sshKeyPath else { return [] }
        let expanded = (keyPath as NSString).expandingTildeInPath
        switch keyFileStatus(expanded) {
        case .missing: throw .keyFileNotFound(keyPath)
        case .tooOpen: throw .keyFilePermissionsTooOpen(keyPath)
        case .ok: return ["-i", expanded, "-o", "IdentitiesOnly=yes"]
        }
    }

    /// ProxyCommand는 ssh가 셸(`$SHELL -c`)로 실행하는 문자열이다.
    /// 각 인자를 셸 인용하고, ssh 토큰 문자 `%`는 `%%`로 이스케이프한다.
    static func proxyCommandValue(_ arguments: [String]) -> String {
        TerminalCommand(executable: arguments[0], arguments: Array(arguments.dropFirst()))
            .shellCommandLine
            .replacingOccurrences(of: "%", with: "%%")
    }

    /// 일반 파일이고 그룹/기타 사용자 권한이 없어야 한다 (OpenSSH와 같은 기준).
    /// 심볼릭 링크인 경우 실제 가리키는 대상 파일의 권한을 확인한다.
    public static func checkKeyFile(_ path: String) -> KeyFileStatus {
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory), !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath),
              let permissions = attributes[.posixPermissions] as? Int else {
            return .missing
        }
        return permissions & 0o077 == 0 ? .ok : .tooOpen
    }
}

extension TerminalCommand {
    /// 터미널에 입력할 한 줄 명령. 각 인자를 POSIX shell 규칙으로 인용해 메타문자가 해석되지 않게 한다.
    public var shellCommandLine: String {
        ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
