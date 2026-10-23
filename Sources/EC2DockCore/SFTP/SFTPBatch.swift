import Foundation

/// sftp 배치 명령 작성과 출력 해석.
/// 파일 이름은 서버에서 온 값이므로 신뢰하지 않는다: 줄바꿈으로 다음 명령을 끼워 넣거나
/// `-`로 시작해 옵션처럼 해석되거나, `*`·`?`가 다른 파일까지 가리키지 않게 한다.
public enum SFTPBatch {
    /// 배치 명령의 경로 인자. 절대 경로만 받고(옵션으로 해석되지 않게) 큰따옴표로 감싼 뒤 `"`만 이스케이프한다.
    /// sftp는 큰따옴표 안의 `*` `?` `[`를 글자 그대로 다룬다(OpenSSH sftp로 확인).
    /// 역슬래시는 따옴표 안에서 다시 이스케이프되어 정확히 표현할 수 없으므로 받지 않는다.
    public static func quote(_ path: String) throws(SFTPError) -> String {
        guard path.hasPrefix("/") else { throw .invalidName(path) }
        guard !path.contains(where: \.isNewline), !path.contains("\\"), !path.contains("\0") else {
            throw .unsupportedName((path as NSString).lastPathComponent)
        }
        return "\"" + path.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func listCommand(_ path: String) throws(SFTPError) -> String {
        // -a: 숨김 파일 포함, -n: 사용자·그룹을 숫자로 받아 이 Mac에서 같은 형식으로 출력하게 한다.
        "ls -lan \(try quote(path))"
    }

    public static func downloadCommand(_ remotePath: String, isDirectory: Bool, to localPath: String) throws(SFTPError) -> String {
        "get\(isDirectory ? " -r" : "") \(try quote(remotePath)) \(try quote(localPath))"
    }

    public static func uploadCommand(_ localPath: String, isDirectory: Bool, to remotePath: String) throws(SFTPError) -> String {
        "put\(isDirectory ? " -r" : "") \(try quote(localPath)) \(try quote(remotePath))"
    }

    public static func makeDirectoryCommand(_ path: String) throws(SFTPError) -> String {
        "mkdir \(try quote(path))"
    }

    // MARK: - 출력 해석

    /// `pwd` 출력: "Remote working directory: /home/ec2-user"
    public static func parseWorkingDirectory(_ output: String) -> String? {
        let prefix = "Remote working directory: "
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
            let path = String(line.dropFirst(prefix.count))
            if path.hasPrefix("/") { return path }
        }
        return nil
    }

    /// `ls -lan <폴더>` 출력. 이름 자리에는 폴더 경로가 붙어 나온다(서버에 따라 이름만 나오기도 한다). 예:
    /// `drwxr-xr-x    ? 1000     1000         4096 Oct 20 10:00 /home/ec2-user/app`
    /// `-rw-r--r--    1 1000     1000          215 Jan  3  2025 old notes.txt`
    /// 배치 모드가 되풀이해 보여주는 "sftp> " 줄과 ".", ".."는 뺀다.
    public static func parseListing(_ output: String, now: Date = Date(), calendar: Calendar = .current) -> [RemoteFileEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("sftp>") else { return nil }
            return parseListingLine(line, now: now, calendar: calendar)
        }
    }

    static func parseListingLine(_ line: Substring, now: Date, calendar: Calendar) -> RemoteFileEntry? {
        var rest = line[...]
        var fields: [Substring] = []
        for _ in 0..<8 {
            rest = rest.drop { $0 == " " }
            guard let end = rest.firstIndex(of: " ") else { return nil }
            fields.append(rest[..<end])
            rest = rest[end...]
        }
        // 마지막 필드(시각 또는 연도) 뒤 공백 하나 다음부터가 경로다. 이름에는 `/`가 없으므로 마지막 `/` 뒤가 이름이다.
        // 이름 앞뒤 공백도 이름의 일부다.
        guard rest.first == " " else { return nil }
        let path = rest.dropFirst()
        let name = String(path.lastIndex(of: "/").map { path[path.index(after: $0)...] } ?? path)
        guard !name.isEmpty, name != ".", name != "..",
              let typeCharacter = fields[0].first, fields[0].count >= 10,
              let size = Int64(fields[4]) else { return nil }

        let kind: RemoteFileEntry.Kind = switch typeCharacter {
        case "d": .directory
        case "-": .file
        case "l": .symlink
        default: .other
        }
        return RemoteFileEntry(name: name, kind: kind, size: size,
                               modified: parseDate(month: fields[5], day: fields[6], timeOrYear: fields[7], now: now, calendar: calendar),
                               permissions: String(fields[0]))
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// ls 형식 날짜: 최근 6개월은 "Oct 20 10:00"(연도 없음), 그 밖은 "Jan  3  2025"(시각 없음).
    static func parseDate(month: Substring, day: Substring, timeOrYear: Substring, now: Date, calendar: Calendar) -> Date? {
        guard let monthIndex = months.firstIndex(of: String(month)), let day = Int(day) else { return nil }
        var components = DateComponents(month: monthIndex + 1, day: day)
        let parts = timeOrYear.split(separator: ":")
        if parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) {
            components.hour = hour
            components.minute = minute
            components.year = calendar.component(.year, from: now)
            // 연도가 없는 날짜가 미래로 계산되면 작년 날짜다.
            if let date = calendar.date(from: components), date > now.addingTimeInterval(86_400) {
                components.year! -= 1
            }
        } else if let year = Int(timeOrYear) {
            components.year = year
        } else {
            return nil
        }
        return calendar.date(from: components)
    }
}

/// sftp(와 그 아래 ssh)의 오류 출력을 원인별로 분류한다.
enum SFTPErrorMapper {
    static func map(stderr: String) -> SFTPError {
        let text = stderr.lowercased()
        func has(_ needle: String) -> Bool { text.contains(needle.lowercased()) }

        if has("REMOTE HOST IDENTIFICATION HAS CHANGED") { return .hostKeyChanged }
        if has("Host key verification failed") || has("No ED25519 host key is known") || has("host key is known for") {
            return .hostKeyUnverified
        }
        if has("Permission denied (") || has("Too many authentication failures") { return .authenticationFailed }
        if has("Connection timed out") || has("Operation timed out") || has("Connection refused") || has("No route to host")
            || has("Connection closed") || has("Could not resolve") || has("Network is unreachable") {
            return .connectionFailed(summary(of: stderr))
        }
        if has("No such file or directory") || has("not found") { return .notFound(summary(of: stderr)) }
        if has("Permission denied") { return .permissionDenied(summary(of: stderr)) }
        return .commandFailed(summary(of: stderr))
    }

    /// 의미 있는 첫 줄만 남긴다 (배치 명령 되풀이 줄 제외).
    static func summary(of stderr: String) -> String {
        let line = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("sftp>") } ?? ""
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}
