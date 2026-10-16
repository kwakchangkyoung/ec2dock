import Foundation
import Testing
@testable import EC2DockCore

/// 실제 AWS 계정에 읽기 전용 호출을 보내는 통합 테스트 (설계서 12.2).
/// 기본적으로 건너뛰며, 환경 변수로 프로필과 리전을 지정했을 때만 실행한다.
///   EC2DOCK_INTEGRATION_PROFILE=<AWS CLI 프로필> EC2DOCK_INTEGRATION_REGION=ap-northeast-2 swift test ...
/// 출력에는 개수만 남기고 계정 ID, IP 등은 기록하지 않는다.
@Suite("AWS integration", .enabled(if: ProcessInfo.processInfo.environment["EC2DOCK_INTEGRATION_PROFILE"] != nil))
struct AWSIntegrationTests {
    let profile = ProcessInfo.processInfo.environment["EC2DOCK_INTEGRATION_PROFILE"] ?? ""
    let region = ProcessInfo.processInfo.environment["EC2DOCK_INTEGRATION_REGION"] ?? "ap-northeast-2"
    let service = AWSCLIDiscoveryService()

    @Test func profileIsListed() async throws {
        #expect(try await service.listProfiles().contains(profile))
    }

    @Test func callerIdentityAndInstancesMatchAccount() async throws {
        let identity = try await service.callerIdentity(profile: profile)
        #expect(InputValidator.isValidAccountID(identity.accountID))

        let instances = try await service.describeInstances(profile: profile, region: region)
        #expect(instances.allSatisfy { $0.region == region && $0.accountID == identity.accountID })
        print("[integration] \(region): \(instances.count) instances, \(instances.filter(\.isRunning).count) running")

        if let first = instances.first {
            let fresh = try await service.describeInstance(profile: profile, region: region, instanceID: first.instanceID)
            #expect(fresh?.instanceID == first.instanceID)
        }
    }
}
