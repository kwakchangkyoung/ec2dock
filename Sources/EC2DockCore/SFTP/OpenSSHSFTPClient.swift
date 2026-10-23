import Darwin
import Foundation

/// macOS 기본 `/usr/bin/sftp`로 파일을 주고받는다. 작업마다 배치 파일을 만들어 실행한다(셸을 거치지 않음).
/// 같은 서버로의 연결은 ssh 연결 재사용(ControlMaster)으로 묶어, 폴더를 옮길 때마다 새로 인증하지 않는다.
/// 접속 명령 전체나 키 경로를 로그로 남기지 않는다.
public struct OpenSSHSFTPClient: SFTPClient {
    private let target: ConnectionTarget
    private let builder: SSHCommandBuilder
    private let runner: any CommandRunner
    private let controlDirectory: String?
    private let now: @Sendable () -> Date

    /// 목록·폴더 만들기 같은 짧은 작업의 제한 시간 (연결 시간 포함)
    static let commandTimeout: Duration = .seconds(60)
    /// 전송은 파일 크기에 따라 오래 걸릴 수 있다. 취소는 사용자가 한다.
    static let transferTimeout: Duration = .seconds(24 * 3600)

    public init(target: ConnectionTarget, builder: SSHCommandBuilder = SSHCommandBuilder(),
                runner: any CommandRunner = ProcessCommandRunner(),
                controlDirectory: String? = SFTPControlDirectory.prepare(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.target = target
        self.builder = builder
        self.runner = runner
        self.controlDirectory = controlDirectory
        self.now = now
    }

    public func homeDirectory() async throws -> String {
        let output = try await run(["pwd"], timeout: Self.commandTimeout)
        guard let path = SFTPBatch.parseWorkingDirectory(output) else { throw SFTPError.commandFailed("홈 폴더를 알 수 없습니다.") }
        return path
    }

    public func list(_ path: String) async throws -> [RemoteFileEntry] {
        let output = try await run([try SFTPBatch.listCommand(path)], timeout: Self.commandTimeout)
        return SFTPBatch.parseListing(output, now: now())
    }

    public func size(of path: String) async throws -> Int64? {
        let output = try await run([try SFTPBatch.listCommand(path)], timeout: Self.commandTimeout)
        let entries = SFTPBatch.parseListing(output, now: now())
        return entries.count == 1 ? entries[0].size : nil
    }

    public func download(_ remotePath: String, isDirectory: Bool, to localURL: URL) async throws {
        _ = try await run([try SFTPBatch.downloadCommand(remotePath, isDirectory: isDirectory, to: localURL.path)],
                          timeout: Self.transferTimeout)
    }

    public func upload(_ localURL: URL, isDirectory: Bool, to remotePath: String) async throws {
        _ = try await run([try SFTPBatch.uploadCommand(localURL.path, isDirectory: isDirectory, to: remotePath)],
                          timeout: Self.transferTimeout)
    }

    public func makeDirectory(_ path: String) async throws {
        _ = try await run([try SFTPBatch.makeDirectoryCommand(path)], timeout: Self.commandTimeout)
    }

    // MARK: - 실행

    private func run(_ commands: [String], timeout: Duration) async throws -> String {
        // 배치 파일은 이 사용자만 읽을 수 있는 임시 폴더에 두고 끝나면 지운다.
        let batchURL = FileManager.default.temporaryDirectory.appending(path: "ec2dock-sftp-\(UUID().uuidString).txt")
        let script = Data((commands.joined(separator: "\n") + "\n").utf8)
        guard FileManager.default.createFile(atPath: batchURL.path, contents: script, attributes: [.posixPermissions: 0o600]) else {
            throw SFTPError.launchFailed
        }
        defer { try? FileManager.default.removeItem(at: batchURL) }

        // 연결 재사용 소켓은 인스턴스 ID별로 나눈다: IP가 다른 인스턴스로 넘어가도 기존 연결을 쓰지 않고 호스트 키를 다시 확인한다.
        let controlPath = controlDirectory.map { "\($0)/\(target.profile.instanceID)-%C" }
        let command = try builder.sftpCommand(for: target, batchFile: batchURL.path, controlPath: controlPath)

        let result: CommandResult
        do {
            result = try await runner.run(URL(fileURLWithPath: command.executable), arguments: command.arguments,
                                          environment: Self.environment(), timeout: timeout)
        } catch CommandRunnerError.timedOut {
            throw SFTPError.timedOut
        } catch CommandRunnerError.launchFailed {
            throw SFTPError.launchFailed
        }
        guard result.exitCode == 0 else {
            throw SFTPErrorMapper.map(stderr: String(decoding: result.stderr, as: UTF8.self))
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    /// ssh-agent 소켓과 기본 경로만 넘긴다. 자격 증명 환경 변수는 넘기지 않는다.
    /// 날짜 형식(영문 월 이름)과 UTF-8 파일 이름 출력을 고정하려고 로캘을 지정한다.
    static func environment() -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var result = ["LC_ALL": "en_US.UTF-8", "SHELL": "/bin/sh"]
        for key in ["SSH_AUTH_SOCK", "PATH", "HOME", "USER", "LOGNAME"] {
            if let value = current[key] { result[key] = value }
        }
        return result
    }
}

/// 연결 재사용 소켓을 둘 폴더. 유닉스 소켓 경로 길이 제한(104바이트) 때문에 짧은 /tmp 아래를 쓴다.
/// 다른 사용자가 미리 만들어 둔 폴더를 쓰지 않도록 소유자와 권한(0700)을 확인하고, 아니면 연결 재사용을 끈다.
public enum SFTPControlDirectory {
    public static func prepare(base: String = "/tmp") -> String? {
        let path = "\(base)/ec2dock-\(getuid())"
        if mkdir(path, 0o700) != 0 && errno != EEXIST { return nil }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { return nil }
        return path
    }
}
