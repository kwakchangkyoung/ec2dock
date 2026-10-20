import Foundation

/// iCloud Drive의 `EC2Dock/ServerProfiles.json` 파일로 동기화한다 (설계서 9.2).
/// 앱 전용 iCloud 컨테이너는 코드 서명과 엔타이틀먼트가 필요하므로, 앱 번들로 배포하기 전까지는
/// 사용자의 iCloud Drive 폴더를 사용한다. 저장 위치만 바꾸면 컨테이너로 옮길 수 있다.
/// 파일 접근은 `NSFileCoordinator`로 조정한다.
public struct ICloudDriveSyncService: SyncService {
    public static let fileName = "ServerProfiles.json"

    /// ~/Library/Mobile Documents/com~apple~CloudDocs/EC2Dock
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
            .appending(path: "EC2Dock", directoryHint: .isDirectory)
    }

    public let directory: URL
    private let locationDescription: String

    public init(directory: URL = ICloudDriveSyncService.defaultDirectory, locationDescription: String = "iCloud Drive/EC2Dock/ServerProfiles.json") {
        self.directory = directory
        self.locationDescription = locationDescription
    }

    var fileURL: URL { directory.appending(path: Self.fileName) }

    public func availability() async -> SyncAvailability {
        let root = directory.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .unavailable(reason: "iCloud Drive를 사용할 수 없습니다.")
        }
        return .available(location: locationDescription)
    }

    public func load() async throws -> SyncSnapshot {
        if case .unavailable(let reason) = await availability() { throw SyncError.unavailable(reason) }
        let url = fileURL
        return try await Self.onBackground {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: url.path) else {
                // 다른 Mac이 올린 파일이 아직 내려받아지지 않았으면 자리표시 파일만 있다.
                let placeholder = url.deletingLastPathComponent().appending(path: ".\(Self.fileName).icloud")
                if fileManager.fileExists(atPath: placeholder.path) {
                    try? fileManager.startDownloadingUbiquitousItem(at: url)
                    throw SyncError.downloading
                }
                return SyncSnapshot(document: nil)
            }

            let data = try Self.coordinatedRead(url)
            let document = try Self.decode(data)
            // 해석할 수 없는 버전 하나 때문에 동기화 전체를 멈추지 않는다. 그 버전은 해결 처리하지 않고 보존한다.
            let versions = (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [])
                .compactMap { version in try? Self.decode(Data(contentsOf: version.url)) }
            return SyncSnapshot(document: document, conflictVersions: versions)
        }
    }

    public func save(_ document: SyncedProfilesDocument, replacing expected: SyncedProfilesDocument?,
                     resolvingConflictVersions: [SyncedProfilesDocument]) async throws {
        if case .unavailable(let reason) = await availability() { throw SyncError.unavailable(reason) }
        let url = fileURL
        let directory = directory
        let data = try Self.encoder.encode(document)
        try await Self.onBackground {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw SyncError.fileAccess("폴더를 만들 수 없습니다.")
            }
            try Self.coordinatedWrite(data, to: url, replacing: expected)
            // 읽은 뒤 새로 생겼거나 해석할 수 없는 버전은 보존한다.
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                guard let data = try? Data(contentsOf: version.url),
                      let document = try? Self.decode(data),
                      resolvingConflictVersions.contains(document) else { continue }
                version.isResolved = true
            }
        }
    }

    // MARK: - File coordination

    private static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(SyncError.fileAccess("읽기 실패"))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if coordinationError != nil { throw SyncError.fileAccess("읽기 조정 실패") }
        do {
            return try result.get()
        } catch {
            throw SyncError.fileAccess("읽기 실패")
        }
    }

    /// 읽은 뒤 다른 Mac이 바꾼 내용을 덮어쓰지 않도록, 같은 조정 구간 안에서 지금 내용을 확인하고 쓴다.
    private static func coordinatedWrite(_ data: Data, to url: URL, replacing expected: SyncedProfilesDocument?) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .failure(SyncError.fileAccess("쓰기 실패"))
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            result = Result {
                let unchanged: Bool
                if FileManager.default.fileExists(atPath: writeURL.path) {
                    let current = try? decode(Data(contentsOf: writeURL))
                    unchanged = current != nil && current == expected
                } else {
                    unchanged = expected == nil
                }
                guard unchanged else { throw SyncError.remoteChanged }
                try data.write(to: writeURL, options: .atomic)
            }
        }
        if coordinationError != nil { throw SyncError.fileAccess("쓰기 조정 실패") }
        do {
            try result.get()
        } catch SyncError.remoteChanged {
            throw SyncError.remoteChanged
        } catch {
            throw SyncError.fileAccess("쓰기 실패")
        }
    }

    /// 지원하지 않는 스키마나 손상된 파일은 덮어쓰지 않도록 오류로 처리한다.
    static func decode(_ data: Data) throws -> SyncedProfilesDocument {
        guard let document = try? decoder.decode(SyncedProfilesDocument.self, from: data) else {
            throw SyncError.invalidDocument
        }
        guard document.schemaVersion <= ServerProfile.currentSchemaVersion else {
            throw SyncError.newerSchema(document.schemaVersion)
        }
        return document
    }

    /// 파일 조정은 동기 호출이고 iCloud 상태에 따라 오래 걸릴 수 있어 별도 큐에서 실행한다.
    private static func onBackground<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
