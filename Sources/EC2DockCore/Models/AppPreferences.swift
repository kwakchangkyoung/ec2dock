import Foundation

public enum LogLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case error
    case info
    case debug

    public var id: String { rawValue }
}

/// PreferencesView에서 편집하는 앱 전체 설정 (설계서 5.2).
public struct AppPreferences: Codable, Equatable, Sendable {
    public var defaultAWSProfile: String
    /// 조회할 AWS CLI 프로필 (FR-001). 비어 있으면 기본 프로필만 조회한다.
    public var enabledAWSProfiles: [String]
    public var defaultRegion: String
    public var regions: [String]
    public var defaultTerminal: String
    /// 0이면 자동 새로고침을 하지 않는다.
    public var autoRefreshIntervalMinutes: Int
    public var confirmProductionConnections: Bool
    public var logLevel: LogLevel
    /// 서버 프로필 iCloud 동기화. 회사 정책 확인이 필요할 수 있어 기본값은 꺼짐 (설계서 9.1).
    public var iCloudSyncEnabled: Bool

    public init(
        defaultAWSProfile: String = "default",
        enabledAWSProfiles: [String] = [],
        defaultRegion: String = "ap-northeast-2",
        regions: [String] = ["ap-northeast-2"],
        defaultTerminal: String = TerminalApp.iTerm2.rawValue,
        autoRefreshIntervalMinutes: Int = 0,
        confirmProductionConnections: Bool = true,
        logLevel: LogLevel = .info,
        iCloudSyncEnabled: Bool = false
    ) {
        self.defaultAWSProfile = defaultAWSProfile
        self.enabledAWSProfiles = enabledAWSProfiles
        self.defaultRegion = defaultRegion
        self.regions = regions
        self.defaultTerminal = defaultTerminal
        self.autoRefreshIntervalMinutes = autoRefreshIntervalMinutes
        self.confirmProductionConnections = confirmProductionConnections
        self.logLevel = logLevel
        self.iCloudSyncEnabled = iCloudSyncEnabled
    }

    /// 저장 파일에 없는 키는 기본값을 사용해 이전 버전 설정도 읽을 수 있게 한다.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppPreferences()
        defaultAWSProfile = try container.decodeIfPresent(String.self, forKey: .defaultAWSProfile) ?? defaults.defaultAWSProfile
        enabledAWSProfiles = try container.decodeIfPresent([String].self, forKey: .enabledAWSProfiles) ?? defaults.enabledAWSProfiles
        defaultRegion = try container.decodeIfPresent(String.self, forKey: .defaultRegion) ?? defaults.defaultRegion
        regions = try container.decodeIfPresent([String].self, forKey: .regions) ?? defaults.regions
        defaultTerminal = try container.decodeIfPresent(String.self, forKey: .defaultTerminal) ?? defaults.defaultTerminal
        autoRefreshIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .autoRefreshIntervalMinutes) ?? defaults.autoRefreshIntervalMinutes
        confirmProductionConnections = try container.decodeIfPresent(Bool.self, forKey: .confirmProductionConnections) ?? defaults.confirmProductionConnections
        logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? defaults.logLevel
        iCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? defaults.iCloudSyncEnabled
    }

    /// 이번 새로고침에서 조회할 프로필 목록
    public var profilesToScan: [String] {
        enabledAWSProfiles.isEmpty ? [defaultAWSProfile] : enabledAWSProfiles
    }
}
