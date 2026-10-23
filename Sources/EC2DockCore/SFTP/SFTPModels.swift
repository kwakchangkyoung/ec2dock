import Foundation

/// 원격 폴더의 항목 하나
public struct RemoteFileEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case directory
        case file
        case symlink
        case other
    }

    public let name: String
    public let kind: Kind
    /// 바이트
    public let size: Int64
    /// 분 단위까지만 알 수 있다 (sftp 목록 형식)
    public let modified: Date?
    /// 예: "drwxr-xr-x"
    public let permissions: String

    public var id: String { name }
    public var isHidden: Bool { name.hasPrefix(".") }
    /// 링크는 가리키는 대상이 폴더일 수 있어 열어 볼 수 있게 한다.
    public var isOpenable: Bool { kind == .directory || kind == .symlink }

    public init(name: String, kind: Kind, size: Int64, modified: Date?, permissions: String) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }
}

/// 서버 파일 접근 계층 (SFTP). 경로는 모두 원격 절대 경로다.
public protocol SFTPClient: Sendable {
    /// 로그인했을 때의 작업 폴더 (보통 홈 폴더)
    func homeDirectory() async throws -> String
    func list(_ path: String) async throws -> [RemoteFileEntry]
    /// 파일 크기 (업로드 진행률 확인용). 없으면 nil.
    func size(of path: String) async throws -> Int64?
    func download(_ remotePath: String, isDirectory: Bool, to localURL: URL) async throws
    func upload(_ localURL: URL, isDirectory: Bool, to remotePath: String) async throws
    func makeDirectory(_ path: String) async throws
}

public enum SFTPError: Error, Equatable, Sendable {
    /// known_hosts에 이 서버의 호스트 키가 없다 (처음 접속)
    case hostKeyUnverified
    /// 기록된 호스트 키와 다르다
    case hostKeyChanged
    case authenticationFailed
    case connectionFailed(String)
    case notFound(String)
    case permissionDenied(String)
    /// 배치 명령으로 안전하게 표현할 수 없는 이름 (줄바꿈, 역슬래시 등)
    case unsupportedName(String)
    case invalidName(String)
    case timedOut
    case launchFailed
    case commandFailed(String)
}

extension SFTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .hostKeyUnverified: "이 서버의 호스트 키를 아직 확인하지 않았습니다."
        case .hostKeyChanged: "서버의 호스트 키가 기록된 값과 다릅니다."
        case .authenticationFailed: "SSH 인증에 실패했습니다."
        case .connectionFailed(let detail): "서버에 연결하지 못했습니다: \(detail)"
        case .notFound(let detail): "파일이나 폴더를 찾을 수 없습니다: \(detail)"
        case .permissionDenied(let detail): "권한이 없습니다: \(detail)"
        case .unsupportedName(let name): "이 이름은 다룰 수 없습니다: \(name)"
        case .invalidName(let name): "이름이 올바르지 않습니다: \(name)"
        case .timedOut: "서버 응답이 없어 중단했습니다."
        case .launchFailed: "sftp를 실행하지 못했습니다."
        case .commandFailed(let detail): "파일 작업에 실패했습니다: \(detail)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .hostKeyUnverified:
            "보안을 위해 파일 화면은 호스트 키를 대신 승인하지 않습니다. 먼저 터미널로 한 번 접속해 호스트 키를 확인한 뒤 다시 시도하세요."
        case .hostKeyChanged:
            "서버가 바뀌었거나 중간에서 가로채는 공격일 수 있습니다. 터미널로 접속해 경고 내용을 확인하세요."
        case .authenticationFailed:
            "접속 설정의 SSH 사용자·키를 확인하세요. 암호가 걸린 키는 터미널에서 ssh-add --apple-use-keychain <키 경로> 로 먼저 등록해야 합니다."
        case .connectionFailed: "서버가 실행 중인지, IP가 바뀌지 않았는지(\"다시 조회\") 확인하세요."
        case .notFound: "목록을 새로 고친 뒤 다시 시도하세요."
        case .permissionDenied: "이 SSH 사용자로 읽거나 쓸 수 있는 위치인지 확인하세요."
        case .unsupportedName: "줄바꿈이나 역슬래시(\\)가 들어간 이름은 지원하지 않습니다. 터미널에서 직접 다루세요."
        case .invalidName: "빈 이름, \".\", \"..\", 슬래시(/)는 쓸 수 없습니다."
        case .timedOut, .commandFailed: "잠시 후 다시 시도하세요."
        case .launchFailed: "/usr/bin/sftp가 있는지 확인하세요."
        }
    }
}

/// 원격 경로 계산 (항상 `/`로 시작하는 절대 경로)
public enum RemotePath {
    public static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    public static func parent(of path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/"), trimmed != "/" else { return "/" }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    /// 경로 막대에 보여줄 단계: [("/", "/"), ("home", "/home"), ("ec2-user", "/home/ec2-user")]
    public static func breadcrumbs(of path: String) -> [(name: String, path: String)] {
        var result: [(name: String, path: String)] = [("/", "/")]
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            result.append((String(component), current))
        }
        return result
    }

    /// 사용자가 입력한 새 이름(새 폴더 등)을 검사한다.
    public static func validateName(_ name: String) throws(SFTPError) {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw .invalidName(name) }
        guard !name.contains(where: \.isNewline), !name.contains("\\"), !name.contains("\0") else { throw .unsupportedName(name) }
    }
}

/// 내려받을 때 이 Mac의 파일을 덮어쓰지 않도록 겹치지 않는 이름을 고른다 ("report (1).txt").
public enum LocalFileNaming {
    public static func uniqueURL(for name: String, in directory: URL,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let candidate = directory.appending(path: name)
        guard exists(candidate) else { return candidate }
        let ext = (name as NSString).pathExtension
        // 숨김 파일(".env")은 확장자 없이 이름 전체를 쓴다.
        let base = ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".")
            ? name : (name as NSString).deletingPathExtension
        let suffix = base == name ? "" : "." + ext
        var number = 1
        while true {
            let url = directory.appending(path: "\(base) (\(number))\(suffix)")
            if !exists(url) { return url }
            number += 1
        }
    }
}
