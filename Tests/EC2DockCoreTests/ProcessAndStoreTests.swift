import Foundation
import Testing
@testable import EC2DockCore

@Suite("ProcessCommandRunner")
struct ProcessCommandRunnerTests {
    let runner = ProcessCommandRunner()

    /// 인자는 shell을 거치지 않으므로 메타문자가 해석되지 않는다.
    @Test func argumentsAreNotInterpretedByShell() async throws {
        let payload = "$(whoami); echo injected `id`"
        let result = try await runner.run(URL(fileURLWithPath: "/bin/echo"), arguments: [payload],
                                          environment: [:], timeout: .seconds(5))
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == payload + "\n")
    }

    @Test func separatesStdoutStderrAndExitCode() async throws {
        let result = try await runner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err 1>&2; exit 3"],
                                          environment: [:], timeout: .seconds(5))
        #expect(result.exitCode == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
    }

    /// 파이프 버퍼(64KB)보다 큰 출력도 멈추지 않고 모두 읽는다.
    @Test func largeOutputDoesNotDeadlock() async throws {
        let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "1000000", "/dev/zero"],
                                          environment: [:], timeout: .seconds(5))
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 1_000_000)
    }

    @Test func timeoutTerminatesProcess() async {
        let start = ContinuousClock.now
        await #expect(throws: CommandRunnerError.timedOut) {
            try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
                                 environment: [:], timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func timeoutKillsProcessIgnoringSIGTERM() async {
        let start = ContinuousClock.now
        await #expect(throws: CommandRunnerError.timedOut) {
            try await runner.run(URL(fileURLWithPath: "/bin/sh"),
                                 arguments: ["-c", "trap '' TERM; exec /bin/sleep 3"],
                                 environment: [:], timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func cancellationKillsProcessIgnoringSIGTERM() async {
        let task = Task {
            try await runner.run(URL(fileURLWithPath: "/bin/sh"),
                                 arguments: ["-c", "trap '' TERM; exec /bin/sleep 3"],
                                 environment: [:], timeout: .seconds(10))
        }
        try? await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test(arguments: ["/bin/sleep 3 & exit 0", "trap '' TERM; /bin/sleep 3 & exit 0"])
    func timeoutIncludesPipesHeldOpenByChild(script: String) async {
        let start = ContinuousClock.now
        await #expect(throws: CommandRunnerError.timedOut) {
            try await runner.run(URL(fileURLWithPath: "/bin/sh"),
                                 arguments: ["-c", script],
                                 environment: [:], timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func missingExecutableFailsToLaunch() async {
        await #expect(throws: CommandRunnerError.launchFailed) {
            try await runner.run(URL(fileURLWithPath: "/nonexistent/aws"), arguments: [],
                                 environment: [:], timeout: .seconds(1))
        }
    }
}

@Suite("JSONFileStore")
struct JSONFileStoreTests {
    private func makeStore() -> JSONFileStore {
        JSONFileStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("EC2DockTests-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func roundTripWithRestrictedPermissions() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let profiles = SampleData.profiles(now: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(try store.load([ServerProfile].self, from: .profiles) == nil)
        try store.save(profiles, to: .profiles)
        #expect(try store.load([ServerProfile].self, from: .profiles) == profiles)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent("ServerProfiles.json").path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        #expect((fileAttributes[.posixPermissions] as? Int) == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? Int) == 0o700)
    }

    @Test func corruptFileIsMovedAsideAndReported() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let url = store.directory.appendingPathComponent(LocalStoreFile.preferences.rawValue)
        try Data("{broken".utf8).write(to: url)

        #expect(throws: (any Error).self) { try store.load(AppPreferences.self, from: .preferences) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(leftovers.contains { $0.hasPrefix("Preferences.json.corrupt-") })
    }

    @Test func preferencesFromOlderVersionUseDefaults() throws {
        let json = #"{"defaultAWSProfile":"work","regions":["us-east-1"]}"#
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
        #expect(preferences.defaultAWSProfile == "work")
        #expect(preferences.regions == ["us-east-1"])
        #expect(preferences.enabledAWSProfiles.isEmpty)
        #expect(preferences.confirmProductionConnections)
        #expect(preferences.profilesToScan == ["work"])
    }
}
