import Foundation

public enum ConnectionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case directSSH
    case bastionSSH
    case ssm

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .directSSH: "Direct SSH"
        case .bastionSSH: "Bastion SSH"
        case .ssm: "SSM"
        }
    }
}

public enum ServerSource: String, Codable, CaseIterable, Sendable {
    case aws
    case manual
}

/// iCloud 동기화 대상인 사용자 설정. 비밀 값이나 기기별 경로를 넣지 않는다.
public struct ServerProfile: Codable, Identifiable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    /// 안정적인 식별자: AWS는 `accountID:region:instanceID`, 수동 추가 서버는 `manual:<uuid>`
    public var id: String {
        switch source {
        case .manual:
            return "manual:\(instanceID)"
        case .aws:
            return Self.makeID(accountID: accountID, region: region, instanceID: instanceID)
        }
    }

    public var source: ServerSource
    public var host: String?

    public var accountID: String
    public var accountAlias: String
    public var region: String
    public var instanceID: String

    public var displayName: String
    public var environment: String
    public var groupName: String
    public var isFavorite: Bool

    public var connectionType: ConnectionType
    public var sshUsername: String
    public var sshPort: Int
    public var bastionProfileID: String?

    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public var isManual: Bool {
        source == .manual
    }

    /// AWS는 known_hosts를 인스턴스 ID 기준으로 기록하고, 수동 추가 서버는 OpenSSH 기본(호스트 기준)을 쓴다.
    public var hostKeyAlias: String? {
        switch source {
        case .aws:
            return instanceID
        case .manual:
            return nil
        }
    }

    public init(
        accountID: String,
        accountAlias: String,
        region: String,
        instanceID: String,
        displayName: String,
        environment: String = "",
        groupName: String = "",
        isFavorite: Bool = false,
        connectionType: ConnectionType = .directSSH,
        sshUsername: String = "ec2-user",
        sshPort: Int = 22,
        bastionProfileID: String? = nil,
        source: ServerSource = .aws,
        host: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        schemaVersion: Int = ServerProfile.currentSchemaVersion
    ) {
        self.accountID = accountID
        self.accountAlias = accountAlias
        self.region = region
        self.instanceID = instanceID
        self.displayName = displayName
        self.environment = environment
        self.groupName = groupName
        self.isFavorite = isFavorite
        self.connectionType = connectionType
        self.sshUsername = sshUsername
        self.sshPort = sshPort
        self.bastionProfileID = bastionProfileID
        self.source = source
        self.host = host
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case source, host
        case accountID, accountAlias, region, instanceID
        case displayName, environment, groupName, isFavorite
        case connectionType, sshUsername, sshPort, bastionProfileID
        case createdAt, updatedAt, schemaVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try container.decodeIfPresent(ServerSource.self, forKey: .source) ?? .aws
        self.host = try container.decodeIfPresent(String.self, forKey: .host)
        self.accountID = try container.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        self.accountAlias = try container.decodeIfPresent(String.self, forKey: .accountAlias) ?? ""
        self.region = try container.decodeIfPresent(String.self, forKey: .region) ?? ""
        self.instanceID = try container.decode(String.self, forKey: .instanceID)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.environment = try container.decodeIfPresent(String.self, forKey: .environment) ?? ""
        self.groupName = try container.decodeIfPresent(String.self, forKey: .groupName) ?? ""
        self.isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        self.connectionType = try container.decodeIfPresent(ConnectionType.self, forKey: .connectionType) ?? .directSSH
        self.sshUsername = try container.decodeIfPresent(String.self, forKey: .sshUsername) ?? "ec2-user"
        self.sshPort = try container.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        self.bastionProfileID = try container.decodeIfPresent(String.self, forKey: .bastionProfileID)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(host, forKey: .host)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(accountAlias, forKey: .accountAlias)
        try container.encode(region, forKey: .region)
        try container.encode(instanceID, forKey: .instanceID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(environment, forKey: .environment)
        try container.encode(groupName, forKey: .groupName)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(connectionType, forKey: .connectionType)
        try container.encode(sshUsername, forKey: .sshUsername)
        try container.encode(sshPort, forKey: .sshPort)
        try container.encodeIfPresent(bastionProfileID, forKey: .bastionProfileID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(schemaVersion, forKey: .schemaVersion)
    }

    public static func manual(
        displayName: String,
        host: String,
        environment: String = "",
        groupName: String = "",
        isFavorite: Bool = false,
        connectionType: ConnectionType = .directSSH,
        sshUsername: String = "ec2-user",
        sshPort: Int = 22,
        bastionProfileID: String? = nil,
        now: Date = Date(),
        uuid: String = UUID().uuidString.lowercased()
    ) -> ServerProfile {
        ServerProfile(
            accountID: "",
            accountAlias: "",
            region: "",
            instanceID: uuid,
            displayName: displayName,
            environment: environment,
            groupName: groupName,
            isFavorite: isFavorite,
            connectionType: connectionType,
            sshUsername: sshUsername,
            sshPort: sshPort,
            bastionProfileID: bastionProfileID,
            source: .manual,
            host: host,
            createdAt: now,
            updatedAt: now,
            schemaVersion: ServerProfile.currentSchemaVersion
        )
    }

    public static func makeID(accountID: String, region: String, instanceID: String) -> String {
        "\(accountID):\(region):\(instanceID)"
    }

    /// Environment 태그를 단어로 나눠 판단한다: "prod", "PRD", "Production-KR", "live", "production01", "운영계" 모두 운영으로 본다.
    /// 운영 접속 확인을 건너뛰지 않도록 흔한 표기를 넓게 받는다. 단, "preprod", "product"처럼 다른 뜻의 단어는 제외한다.
    public var isProduction: Bool {
        environmentWords.contains { word in
            // "운영계", "운영서버"처럼 한국어는 뒤에 말이 붙는다.
            word.hasPrefix("운영") || ["production", "prod", "prd", "live"].contains { keyword in
                // 뒤에 숫자만 붙은 것("prod2", "production01")도 운영으로 본다.
                word.hasPrefix(keyword) && word.dropFirst(keyword.count).allSatisfy(\.isNumber)
            }
        }
    }

    public var isDevelopment: Bool {
        !environmentWords.isDisjoint(with: ["development", "develop", "dev", "개발"])
    }

    private var environmentWords: Set<String> {
        Set(environment.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// AWS에서 새로 발견한 인스턴스의 기본 프로필. Name/Environment 태그를 사용한다.
    public static func discovered(from instance: EC2Instance, accountAlias: String, now: Date) -> ServerProfile {
        ServerProfile(
            accountID: instance.accountID,
            accountAlias: accountAlias,
            region: instance.region,
            instanceID: instance.instanceID,
            displayName: instance.name ?? instance.instanceID,
            environment: instance.environmentTag ?? "",
            createdAt: now,
            updatedAt: now
        )
    }
}
