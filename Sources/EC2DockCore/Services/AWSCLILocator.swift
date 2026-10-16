import Foundation

/// `aws` 실행 파일 위치 탐색. 경로를 하나로 고정 가정하지 않는다 (설계서 7.3).
/// Finder에서 실행한 앱은 PATH가 최소값이므로 일반적인 설치 위치를 먼저 확인한다.
public enum AWSCLILocator {
    public static let wellKnownPaths = [
        "/opt/homebrew/bin/aws",
        "/usr/local/bin/aws",
        "/usr/bin/aws",
    ]

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }   // 상대 경로(.)는 탐색하지 않는다.
            .map { ($0 as NSString).appendingPathComponent("aws") }

        var seen = Set<String>()
        for path in wellKnownPaths + pathEntries where seen.insert(path).inserted {
            if isExecutable(path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}
