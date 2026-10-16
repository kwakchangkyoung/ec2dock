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

/// iCloud 동기화 대상인 사용자 설정. 비밀 값이나 기기별 경로를 넣지 않는다.
public struct ServerProfile: Codable, Identifiable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    /// 안정적인 식별자: `AWS account ID + region + instance ID` (설계서 6.1)
    public var id: String {
        Self.makeID(accountID: accountID, region: region, instanceID: instanceID)
    }

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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public static func makeID(accountID: String, region: String, instanceID: String) -> String {
        "\(accountID):\(region):\(instanceID)"
    }

    public var isProduction: Bool {
        environment.caseInsensitiveCompare("production") == .orderedSame
    }

    public var isDevelopment: Bool {
        environment.caseInsensitiveCompare("development") == .orderedSame
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
