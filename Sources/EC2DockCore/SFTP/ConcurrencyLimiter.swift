import Foundation

/// 동시에 실행하는 작업 수를 제한한다. 자리가 없으면 들어온 순서대로 기다린다.
/// 파일 전송은 서버 연결 하나를 나눠 쓰는데(ssh 연결 재사용), sshd는 연결 하나의 동시 세션을
/// 기본 10개(MaxSessions)로 제한하므로 한꺼번에 많이 보내면 일부가 거부된다.
public actor ConcurrencyLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// 자리가 나면 `onStart`를 부른 뒤 `work`를 실행한다. 기다리는 동안 취소되면 실행하지 않고 `CancellationError`를 던진다.
    public func run<T: Sendable>(onStart: @Sendable () async -> Void = {},
                                 _ work: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        await onStart()
        return try await work()
    }

    private func acquire() async throws {
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // 자리는 release()에서 그대로 넘겨받았으므로 running은 이미 센 상태다.
    }

    /// 기다리는 작업이 있으면 자리를 넘기고, 없으면 자리를 비운다.
    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
