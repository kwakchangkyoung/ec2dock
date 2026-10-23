import Foundation
import Testing
@testable import EC2DockCore

/// 동시에 실행 중인 수와 시작 순서를 기록한다.
private actor Tracker {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var started: [Int] = []

    func begin(_ index: Int) {
        current += 1
        peak = max(peak, current)
        started.append(index)
    }

    func end() { current -= 1 }
}

private struct Boom: Error {}

@Suite("ConcurrencyLimiter")
struct ConcurrencyLimiterTests {
    /// 많이 보내도 한 번에 limit개까지만 실행하고, 들어온 순서대로 시작한다.
    @Test func neverExceedsLimitAndStartsInOrder() async throws {
        let limiter = ConcurrencyLimiter(limit: 3)
        let tracker = Tracker()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    try await limiter.run(onStart: { await tracker.begin(index) }) {
                        try await Task.sleep(for: .milliseconds(20))
                        await tracker.end()
                    }
                }
                // 대기열에 들어가는 순서를 고정한다.
                try await Task.sleep(for: .milliseconds(2))
            }
            try await group.waitForAll()
        }
        #expect(await tracker.peak == 3)
        #expect(await tracker.started == Array(0..<12))
    }

    /// 기다리는 중에 취소하면 실행하지 않고, 자리도 차지하지 않는다.
    @Test func cancellingWaiterSkipsWorkAndFreesQueue() async throws {
        let limiter = ConcurrencyLimiter(limit: 1)
        let tracker = Tracker()
        let blocker = Task {
            try await limiter.run(onStart: { await tracker.begin(0) }) {
                try await Task.sleep(for: .milliseconds(150))
                await tracker.end()
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let waiting = Task {
            try await limiter.run(onStart: { await tracker.begin(1) }) { await tracker.end() }
        }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }

        let after = Task {
            try await limiter.run(onStart: { await tracker.begin(2) }) { await tracker.end() }
        }
        try await blocker.value
        try await after.value
        #expect(await tracker.started == [0, 2])
    }

    /// 작업이 실패해도 자리를 돌려준다.
    @Test func failureReleasesSlot() async throws {
        let limiter = ConcurrencyLimiter(limit: 1)
        await #expect(throws: Boom.self) {
            try await limiter.run { throw Boom() }
        }
        let value = try await limiter.run { 42 }
        #expect(value == 42)
    }
}
