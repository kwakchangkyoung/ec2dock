import Foundation

/// iCloud에 저장하는 문서. `ServerProfile`만 담으며
/// `LocalConnectionSettings`(키 경로, AWS CLI 프로필 매핑)와 IP 캐시는 구조적으로 포함할 수 없다.
public struct SyncedProfilesDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var profiles: [ServerProfile]

    public init(schemaVersion: Int = ServerProfile.currentSchemaVersion, profiles: [ServerProfile]) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
    }
}

/// iCloud에서 읽은 상태
public struct SyncSnapshot: Equatable, Sendable {
    /// 현재 파일 (아직 없으면 nil)
    public var document: SyncedProfilesDocument?
    /// 여러 Mac이 오프라인에서 동시에 저장해 iCloud가 남긴 다른 파일 버전들
    public var conflictVersions: [SyncedProfilesDocument]

    public init(document: SyncedProfilesDocument?, conflictVersions: [SyncedProfilesDocument] = []) {
        self.document = document
        self.conflictVersions = conflictVersions
    }
}

public enum SyncAvailability: Equatable, Sendable {
    /// location은 사용자에게 보여줄 저장 위치
    case available(location: String)
    case unavailable(reason: String)
}

public enum SyncError: Error, Equatable, Sendable {
    case unavailable(String)
    case downloading
    case newerSchema(Int)
    case invalidDocument
    case fileAccess(String)
}

extension SyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .downloading: "iCloud에서 파일을 내려받는 중입니다."
        case .newerSchema(let version): "더 새로운 버전의 EC2Dock이 저장한 데이터입니다 (스키마 \(version))."
        case .invalidDocument: "iCloud의 동기화 파일을 해석할 수 없습니다."
        case .fileAccess(let message): "iCloud 파일에 접근하지 못했습니다: \(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unavailable: "시스템 설정 > Apple 계정 > iCloud에서 iCloud Drive를 켜세요. 그동안 이 Mac에서는 로컬 모드로 계속 동작합니다."
        case .downloading: "잠시 후 자동으로 다시 시도합니다."
        case .newerSchema: "이 Mac의 EC2Dock을 최신 버전으로 업데이트하세요. 데이터를 덮어쓰지 않았습니다."
        case .invalidDocument: "파일을 덮어쓰지 않았습니다. iCloud Drive의 EC2Dock 폴더를 확인하세요."
        case .fileAccess: "iCloud Drive 연결 상태를 확인한 뒤 다시 시도하세요."
        }
    }
}

public enum SyncStatus: Equatable, Sendable {
    case disabled
    case syncing
    case synced(Date)
    case conflicts(Int)
    case failed(String)

    public var summary: String {
        switch self {
        case .disabled: "사용 안 함 (로컬 모드)"
        case .syncing: "동기화 중…"
        case .synced(let date): "동기화됨 · \(date.formatted(date: .omitted, time: .shortened))"
        case .conflicts(let count): "충돌 \(count)건 · 해결이 필요합니다"
        case .failed(let message): "동기화 실패 · 로컬 모드로 계속 동작 (\(message))"
        }
    }
}

/// iCloud 동기화 저장소 계층
public protocol SyncService: Sendable {
    func availability() async -> SyncAvailability
    func load() async throws -> SyncSnapshot
    /// 문서를 저장하고, 호출자가 병합을 완료한 충돌 버전만 해결 처리한다.
    func save(_ document: SyncedProfilesDocument, resolvingConflictVersions: [SyncedProfilesDocument]) async throws
}

extension SyncService {
    public func save(_ document: SyncedProfilesDocument) async throws {
        try await save(document, resolvingConflictVersions: [])
    }
}
