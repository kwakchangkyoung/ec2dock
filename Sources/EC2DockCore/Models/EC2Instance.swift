import Foundation

/// AWS에서 조회한 관측 데이터. 사용자 설정(`ServerProfile`)과 섞어 저장하지 않는다.
/// 로컬 캐시(InstanceCache.json)에만 저장한다.
public struct EC2Instance: Codable, Identifiable, Equatable, Sendable {
    public var id: String {
        ServerProfile.makeID(accountID: accountID, region: region, instanceID: instanceID)
    }

    public var accountID: String
    public var region: String
    public var instanceID: String
    public var name: String?

    public var state: String
    public var publicIPAddress: String?
    public var privateIPAddress: String?
    public var availabilityZone: String?
    public var instanceType: String?
    /// Bastion 후보를 같은 VPC로 좁히는 데 쓴다. 이전 캐시에는 없을 수 있다.
    public var vpcID: String?
    public var tags: [String: String]

    public var lastFetchedAt: Date

    /// `name`을 지정하지 않으면 `Name` 태그에서 추출한다.
    public init(
        accountID: String,
        region: String,
        instanceID: String,
        name: String? = nil,
        state: String,
        publicIPAddress: String? = nil,
        privateIPAddress: String? = nil,
        availabilityZone: String? = nil,
        instanceType: String? = nil,
        vpcID: String? = nil,
        tags: [String: String] = [:],
        lastFetchedAt: Date
    ) {
        self.accountID = accountID
        self.region = region
        self.instanceID = instanceID
        self.state = state
        self.publicIPAddress = publicIPAddress
        self.privateIPAddress = privateIPAddress
        self.availabilityZone = availabilityZone
        self.instanceType = instanceType
        self.vpcID = vpcID
        self.tags = tags
        self.lastFetchedAt = lastFetchedAt
        self.name = name ?? Self.tag(named: "Name", in: tags)
    }

    public var isRunning: Bool { state == "running" }

    public var environmentTag: String? { Self.tag(named: "Environment", in: tags) }

    /// 정확히 일치하는 키를 우선하고, 없으면 대소문자를 무시해 찾는다.
    static func tag(named key: String, in tags: [String: String]) -> String? {
        if let exact = tags[key] { return exact }
        return tags.keys.sorted()
            .first { $0.caseInsensitiveCompare(key) == .orderedSame }
            .flatMap { tags[$0] }
    }
}
