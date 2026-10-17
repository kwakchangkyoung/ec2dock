import Darwin
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
        handle.didLaunch()
        defer { handle.complete() }

        let result = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandResult.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    async let stdout = Self.readToEnd(stdoutPipe.fileHandleForReading, handle: handle)
                    async let stderr = Self.readToEnd(stderrPipe.fileHandleForReading, handle: handle)
                    let exitCode = await handle.waitForExit()
                    return await CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    handle.terminate()
                    throw CommandRunnerError.timedOut
                }
                // 자식이 파이프를 계속 열어 둔 경우도 전체 실행 시간에 포함한다.
                return try await group.next()!
            }
        } onCancel: {
            handle.terminate()
        }
        try Task.checkCancellation()

        return result
    }

    private static func readToEnd(_ fileHandle: FileHandle, handle: ProcessHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                defer { try? fileHandle.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 65_536)
                var descriptor = pollfd(fd: fileHandle.fileDescriptor, events: Int16(POLLIN), revents: 0)
                // 무기한 read 대신 주기적으로 종료 요청을 확인한다.
                while !handle.shouldStopReading {
                    let ready = poll(&descriptor, 1, 50)
                    if ready < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    if ready == 0 { continue }
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(descriptor.fd, $0.baseAddress, $0.count)
                    }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                continuation.resume(returning: data)
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
    private var processGroup: pid_t?
    private var terminationRequested = false
    private var completed = false
    private var stopReading = false

    init(_ process: Process) {
        self.process = process
    }

    func didLaunch() {
        lock.lock()
        defer { lock.unlock() }
        let pid = process.processIdentifier
        // Foundation이 만든 독립 그룹만 종료한다. 부모 앱의 그룹은 건드리지 않는다.
        if getpgid(pid) == pid { processGroup = pid }
    }

    var shouldStopReading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopReading
    }

    func complete() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    func finish(_ status: Int32) {
        lock.lock()
        exitStatus = status
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: status)
        } else {
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
        lock.lock()
        guard !completed, !terminationRequested else {
            lock.unlock()
            return
        }
        terminationRequested = true
        signal(SIGTERM)
        lock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(500)) {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.completed else { return }
            self.signal(SIGKILL)
            self.stopReading = true
        }
    }

    /// lock을 잡은 상태에서만 호출한다.
    private func signal(_ value: Int32) {
        if let processGroup {
            kill(-processGroup, value)
        } else if exitStatus == nil, process.isRunning {
            kill(process.processIdentifier, value)
        }
    }
}
