import Foundation

/// 이 Mac에만 저장하는 파일. iCloud 동기화는 Phase 5에서 `SyncService`가 별도로 담당한다.
public enum LocalStoreFile: String, CaseIterable, Sendable {
    case profiles = "ServerProfiles.json"
    case localSettings = "LocalConnectionSettings.json"
    case preferences = "Preferences.json"
    case instanceCache = "InstanceCache.json"
    /// 마지막으로 iCloud와 맞춘 프로필 (3-way 병합 기준)
    case syncBase = "SyncBase.json"
    /// 아직 처리 중인 오프라인 파일 버전에서 사용자가 해결한 프로필
    case syncVersionResolutions = "SyncVersionResolutions.json"
    /// 계정 ID → AWS CLI 프로필 (이 Mac의 프로필 이름이므로 동기화하지 않음)
    case accountProfiles = "AccountProfiles.json"
}

public protocol LocalStore: Sendable {
    func load<T: Decodable>(_ type: T.Type, from file: LocalStoreFile) throws -> T?
    func save<T: Encodable>(_ value: T, to file: LocalStoreFile) throws
}

/// `~/Library/Application Support/EC2Dock/` 아래 JSON 파일 저장소.
/// 디렉터리는 0700, 파일은 0600 권한으로 만든다. 비밀 값은 저장하지 않는다.
public struct JSONFileStore: LocalStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var applicationSupport: JSONFileStore {
        JSONFileStore(directory: URL.applicationSupportDirectory.appending(path: "EC2Dock", directoryHint: .isDirectory))
    }

    public func load<T: Decodable>(_ type: T.Type, from file: LocalStoreFile) throws -> T? {
        let url = directory.appendingPathComponent(file.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            // 손상된 파일은 덮어쓰기 전에 옆으로 옮겨 둔다.
            let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            throw error
        }
    }

    public func save<T: Encodable>(_ value: T, to file: LocalStoreFile) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(file.rawValue)
        try Self.encoder.encode(value).write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
