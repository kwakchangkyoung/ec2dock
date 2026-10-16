import Foundation

/// 목록/상세 화면에 표시하는 조합 뷰 모델. 저장하지 않는다.
public struct ServerListItem: Identifiable, Equatable, Sendable {
    public let profile: ServerProfile
    /// 마지막으로 관측한 AWS 상태. 한 번도 조회되지 않았으면 nil.
    public let instance: EC2Instance?

    public init(profile: ServerProfile, instance: EC2Instance?) {
        self.profile = profile
        self.instance = instance
    }

    public var id: String { profile.id }
    public var stateLabel: String { instance?.state ?? "unknown" }
}

public enum ServerFilter: Hashable, Sendable {
    case all
    case favorites
    case production
    case development
    case account(String)

    public func includes(_ profile: ServerProfile) -> Bool {
        switch self {
        case .all: true
        case .favorites: profile.isFavorite
        case .production: profile.isProduction
        case .development: profile.isDevelopment
        case .account(let accountID): profile.accountID == accountID
        }
    }
}

public struct AccountSummary: Identifiable, Equatable, Sendable {
    /// 아직 조회 전인 프로필은 "profile:<이름>" 형태의 임시 ID를 쓴다.
    public let accountID: String
    public let alias: String
    public let serverCount: Int
    /// 이 계정을 조회하는 이 Mac의 AWS CLI 프로필
    public let awsProfile: String?
    /// 조회 대상이지만 아직 한 번도 조회되지 않은 프로필
    public let isPending: Bool
    /// 이 Mac에서 조회 대상인 프로필로 연결된 계정인지 (아니면 캐시·동기화된 서버만 있음)
    public let isScanned: Bool

    public init(accountID: String, alias: String, serverCount: Int, awsProfile: String? = nil,
                isPending: Bool = false, isScanned: Bool = true) {
        self.accountID = accountID
        self.alias = alias
        self.serverCount = serverCount
        self.awsProfile = awsProfile
        self.isPending = isPending
        self.isScanned = isScanned
    }

    public var id: String { accountID }
}

/// 검색어를 어느 항목에서 찾을지 (FR-004 확장)
public enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case name
    case instanceID
    case publicIP
    case privateIP
    case tag

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "전체"
        case .name: "이름"
        case .instanceID: "인스턴스 ID"
        case .publicIP: "공인 IP"
        case .privateIP: "사설 IP"
        case .tag: "태그"
        }
    }

    func fields(of item: ServerListItem) -> [String] {
        let profile = item.profile
        let instance = item.instance
        let names = [profile.displayName, instance?.name].compactMap { $0 }
        let tags = (instance?.tags ?? [:]).flatMap { [$0.key, $0.value] }
        switch self {
        case .name: return names
        case .instanceID: return [profile.instanceID]
        case .publicIP: return [instance?.publicIPAddress].compactMap { $0 }
        case .privateIP: return [instance?.privateIPAddress].compactMap { $0 }
        case .tag: return tags
        case .all:
            return names + tags + [profile.instanceID, profile.region, profile.accountAlias, profile.groupName, profile.environment]
                + [instance?.publicIPAddress, instance?.privateIPAddress, instance?.instanceType, instance?.availabilityZone]
                    .compactMap { $0 }
        }
    }
}

/// 인스턴스 상태로 거르기
public enum InstanceStateFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case running
    case stopped

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "전체"
        case .running: "실행 중"
        case .stopped: "중지됨"
        }
    }

    public func includes(_ instance: EC2Instance?) -> Bool {
        switch self {
        case .all: true
        case .running: instance?.state == "running"
        case .stopped: instance?.state == "stopped" || instance?.state == "stopping"
        }
    }
}

/// FR-004: 이름, 인스턴스 ID, IP, 태그 등으로 검색
public enum ServerSearch {
    public static func matches(_ item: ServerListItem, query: String, scope: SearchScope = .all) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return scope.fields(of: item).contains { $0.localizedCaseInsensitiveContains(query) }
    }

    public static func filter(
        _ items: [ServerListItem],
        by filter: ServerFilter,
        query: String,
        scope: SearchScope = .all,
        state: InstanceStateFilter = .all
    ) -> [ServerListItem] {
        items
            .filter { filter.includes($0.profile) && state.includes($0.instance) && matches($0, query: query, scope: scope) }
            .sorted { $0.profile.displayName.localizedStandardCompare($1.profile.displayName) == .orderedAscending }
    }
}
