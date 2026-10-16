import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandRunnerError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
}

/// 외부 명령 실행 계층. 항상 실행 파일 + 인자 배열로 실행하며 shell을 거치지 않는다 (설계서 10.3).
public protocol CommandRunner: Sendable {
    func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration
    ) async throws -> CommandResult
}

/// `Process` 기반 구현. stdout/stderr를 따로 수집하고 타임아웃과 Task 취소 시 프로세스를 종료한다.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let handle = ProcessHandle(process)
        process.terminationHandler = { handle.finish($0.terminationStatus) }

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed
        }

        // 파이프 버퍼가 가득 차 멈추지 않도록 종료를 기다리는 동안 계속 읽는다.
        async let stdout = Self.readToEnd(stdoutPipe.fileHandleForReading)
        async let stderr = Self.readToEnd(stderrPipe.fileHandleForReading)

        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32?.self) { group in
                group.addTask { await handle.waitForExit() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                guard let status = first else {
                    handle.terminate()
                    throw CommandRunnerError.timedOut
                }
                return status
            }
        } onCancel: {
            handle.terminate()
        }
        try Task.checkCancellation()

        return CommandResult(exitCode: exitCode, stdout: await stdout, stderr: await stderr)
    }

    private static func readToEnd(_ fileHandle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: (try? fileHandle.readToEnd()) ?? Data())
            }
        }
    }
}

/// `Process`와 종료 대기 상태를 스레드 안전하게 감싼다.
private final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    init(_ process: Process) {
        self.process = process
    }

    func finish(_ status: Int32) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: status)
        } else {
            exitStatus = status
            lock.unlock()
        }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
