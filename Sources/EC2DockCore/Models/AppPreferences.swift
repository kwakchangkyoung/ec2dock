import Foundation

/// 목록 한 줄의 밀도
public enum ServerListDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case comfortable
    case compact

    public var id: String { rawValue }
    public var displayName: String { self == .comfortable ? "기본" : "간결" }
}

/// 내장 터미널 색상 테마
public enum TerminalTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case dark
    case light
    case system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dark: "어두운 테마"
        case .light: "밝은 테마"
        case .system: "시스템 설정 따르기"
        }
    }
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
    /// 서버 프로필 iCloud 동기화. 회사 정책 확인이 필요할 수 있어 기본값은 꺼짐 (설계서 9.1).
    public var iCloudSyncEnabled: Bool
    // 목록 보기
    public var listDensity: ServerListDensity
    public var listSort: ServerSortOrder
    public var listGrouping: ServerGrouping
    // 내장 터미널
    public var terminalFontSize: Double
    public var terminalTheme: TerminalTheme
    /// 터미널 탭을 보는 동안 사이드바와 목록을 자동으로 접는다.
    public var autoFocusTerminal: Bool
    /// iTerm2로 열 때 열린 창이 있으면 새 탭으로 연다.
    public var iTermOpensNewTab: Bool

    public static let terminalFontSizeRange: ClosedRange<Double> = 9...28
    public static let defaultTerminalFontSize: Double = 13

    public init(
        defaultAWSProfile: String = "default",
        enabledAWSProfiles: [String] = [],
        defaultRegion: String = "ap-northeast-2",
        regions: [String] = ["ap-northeast-2"],
        defaultTerminal: String = TerminalApp.iTerm2.rawValue,
        autoRefreshIntervalMinutes: Int = 0,
        confirmProductionConnections: Bool = true,
        iCloudSyncEnabled: Bool = false,
        listDensity: ServerListDensity = .comfortable,
        listSort: ServerSortOrder = .name,
        listGrouping: ServerGrouping = .none,
        terminalFontSize: Double = AppPreferences.defaultTerminalFontSize,
        terminalTheme: TerminalTheme = .dark,
        autoFocusTerminal: Bool = true,
        iTermOpensNewTab: Bool = false
    ) {
        self.defaultAWSProfile = defaultAWSProfile
        self.enabledAWSProfiles = enabledAWSProfiles
        self.defaultRegion = defaultRegion
        self.regions = regions
        self.defaultTerminal = defaultTerminal
        self.autoRefreshIntervalMinutes = autoRefreshIntervalMinutes
        self.confirmProductionConnections = confirmProductionConnections
        self.iCloudSyncEnabled = iCloudSyncEnabled
        self.listDensity = listDensity
        self.listSort = listSort
        self.listGrouping = listGrouping
        self.terminalFontSize = terminalFontSize
        self.terminalTheme = terminalTheme
        self.autoFocusTerminal = autoFocusTerminal
        self.iTermOpensNewTab = iTermOpensNewTab
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
        iCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? defaults.iCloudSyncEnabled
        listDensity = (try? container.decodeIfPresent(ServerListDensity.self, forKey: .listDensity)) ?? defaults.listDensity
        listSort = (try? container.decodeIfPresent(ServerSortOrder.self, forKey: .listSort)) ?? defaults.listSort
        listGrouping = (try? container.decodeIfPresent(ServerGrouping.self, forKey: .listGrouping)) ?? defaults.listGrouping
        terminalFontSize = try container.decodeIfPresent(Double.self, forKey: .terminalFontSize) ?? defaults.terminalFontSize
        terminalTheme = (try? container.decodeIfPresent(TerminalTheme.self, forKey: .terminalTheme)) ?? defaults.terminalTheme
        autoFocusTerminal = try container.decodeIfPresent(Bool.self, forKey: .autoFocusTerminal) ?? defaults.autoFocusTerminal
        iTermOpensNewTab = try container.decodeIfPresent(Bool.self, forKey: .iTermOpensNewTab) ?? defaults.iTermOpensNewTab
    }

    /// 터미널 글꼴 크기를 `delta`만큼 바꾼다 (허용 범위 안에서).
    public mutating func adjustTerminalFontSize(by delta: Double) {
        let range = Self.terminalFontSizeRange
        terminalFontSize = min(max(terminalFontSize + delta, range.lowerBound), range.upperBound)
    }

    /// 이번 새로고침에서 조회할 프로필 목록
    public var profilesToScan: [String] {
        enabledAWSProfiles.isEmpty ? [defaultAWSProfile] : enabledAWSProfiles
    }
}
