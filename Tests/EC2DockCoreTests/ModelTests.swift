import Foundation
import Testing
@testable import EC2DockCore

private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("ServerProfile / EC2Instance")
struct ModelTests {
    @Test func profileIDCombinesAccountRegionAndInstance() {
        let profile = ServerProfile(accountID: "111111111111", accountAlias: "a", region: "ap-northeast-2",
                                    instanceID: "i-0123456789abcdef0", displayName: "web",
                                    createdAt: fixedDate, updatedAt: fixedDate)
        #expect(profile.id == "111111111111:ap-northeast-2:i-0123456789abcdef0")
    }

    @Test func sameInstanceIDInDifferentAccountOrRegionIsDistinct() {
        let a = ServerProfile.makeID(accountID: "111111111111", region: "ap-northeast-2", instanceID: "i-0123abcd")
        let b = ServerProfile.makeID(accountID: "222222222222", region: "ap-northeast-2", instanceID: "i-0123abcd")
        let c = ServerProfile.makeID(accountID: "111111111111", region: "us-east-1", instanceID: "i-0123abcd")
        #expect(Set([a, b, c]).count == 3)
    }

    @Test func profileCodableRoundTrip() throws {
        let profile = SampleData.profiles(now: fixedDate)[1]
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: data)
        #expect(decoded == profile)
    }

    @Test func instanceNameComesFromNameTag() {
        let instance = EC2Instance(accountID: "111111111111", region: "us-east-1", instanceID: "i-0123abcd",
                                   state: "running", tags: ["Name": "api-01"], lastFetchedAt: fixedDate)
        #expect(instance.name == "api-01")
    }

    @Test func explicitNameWinsOverTag() {
        let instance = EC2Instance(accountID: "111111111111", region: "us-east-1", instanceID: "i-0123abcd",
                                   name: "explicit", state: "running", tags: ["Name": "tag"], lastFetchedAt: fixedDate)
        #expect(instance.name == "explicit")
    }

    @Test func environmentTagIsCaseInsensitive() {
        let instance = EC2Instance(accountID: "111111111111", region: "us-east-1", instanceID: "i-0123abcd",
                                   state: "running", tags: ["environment": "Production"], lastFetchedAt: fixedDate)
        #expect(instance.environmentTag == "Production")
    }

    @Test func discoveredProfileUsesTagsAndFallsBackToInstanceID() {
        let tagged = EC2Instance(accountID: "111111111111", region: "us-east-1", instanceID: "i-0123abcd",
                                 state: "running", tags: ["Name": "worker", "Environment": "Development"],
                                 lastFetchedAt: fixedDate)
        let untagged = EC2Instance(accountID: "111111111111", region: "us-east-1", instanceID: "i-0456abcd",
                                   state: "running", lastFetchedAt: fixedDate)

        let p1 = ServerProfile.discovered(from: tagged, accountAlias: "acme", now: fixedDate)
        let p2 = ServerProfile.discovered(from: untagged, accountAlias: "acme", now: fixedDate)

        #expect(p1.displayName == "worker")
        #expect(p1.isDevelopment)
        #expect(p1.id == tagged.id)
        #expect(p2.displayName == "i-0456abcd")
        #expect(p2.environment.isEmpty)
    }

    @Test func instanceWithoutIPsIsHandled() {
        let instance = EC2Instance(accountID: "111111111111", region: "us-east-1", instanceID: "i-0123abcd",
                                   state: "stopped", lastFetchedAt: fixedDate)
        #expect(instance.publicIPAddress == nil)
        #expect(instance.privateIPAddress == nil)
        #expect(!instance.isRunning)
    }

    @Test func sampleDataIsValid() {
        for profile in SampleData.profiles(now: fixedDate) {
            #expect(InputValidator.validate(profile).isEmpty, "\(profile.displayName)")
        }
    }
}

@Suite("Search & Filter")
struct SearchTests {
    private let items: [ServerListItem] = {
        let instances = Dictionary(uniqueKeysWithValues: SampleData.cachedInstances(now: fixedDate).map { ($0.id, $0) })
        return SampleData.profiles(now: fixedDate).map { ServerListItem(profile: $0, instance: instances[$0.id]) }
    }()

    private func names(_ filter: ServerFilter, _ query: String = "") -> [String] {
        ServerSearch.filter(items, by: filter, query: query).map(\.profile.displayName)
    }

    @Test func emptyQueryReturnsAllSorted() {
        let result = names(.all)
        #expect(result.count == items.count)
        #expect(result == result.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func searchByNameIsCaseInsensitive() {
        #expect(names(.all, "PROD-WEB") == ["prod-web-01"])
    }

    @Test func searchByInstanceID() {
        #expect(names(.all, "i-0b1c2d3e4f5a60002") == ["dev-db-01"])
    }

    @Test func searchByTagValueAndKey() {
        #expect(names(.all, "bastion") == ["prod-bastion"])
        #expect(Set(names(.all, "Team")) == ["prod-web-01", "prod-api-01", "prod-batch-01", "dev-db-01"])
        #expect(Set(names(.all, "backend")) == ["prod-api-01", "dev-db-01"])
    }

    @Test func whitespaceOnlyQueryMatchesAll() {
        #expect(names(.all, "   ").count == items.count)
    }

    @Test func favoritesFilter() {
        #expect(Set(names(.favorites)) == ["prod-web-01", "dev-db-01"])
    }

    @Test func environmentFilters() {
        #expect(names(.production).count == 4)
        #expect(names(.development).count == 3)
    }

    @Test func accountFilterCombinesWithSearch() {
        #expect(names(.account(SampleData.devAccountID), "web") == ["dev-web-01"])
    }
}

@Suite("AWSRegions")
struct AWSRegionsTests {
    @Test func knownRegionsAreValidAndUnique() {
        let codes = AWSRegions.known.map(\.code)
        #expect(codes.allSatisfy(InputValidator.isValidRegion))
        #expect(Set(codes).count == codes.count)
    }

    @Test func displayName() {
        #expect(AWSRegions.displayName(for: "ap-northeast-2") == "ap-northeast-2 (서울)")
        #expect(AWSRegions.displayName(for: "xx-test-1") == "xx-test-1")
    }
}

@Suite("Search scopes & state filter")
struct SearchScopeTests {
    private let items: [ServerListItem] = {
        let instances = Dictionary(uniqueKeysWithValues: SampleData.cachedInstances(now: fixedDate).map { ($0.id, $0) })
        return SampleData.profiles(now: fixedDate).map { ServerListItem(profile: $0, instance: instances[$0.id]) }
    }()

    private func names(_ query: String, scope: SearchScope = .all, state: InstanceStateFilter = .all) -> Set<String> {
        Set(ServerSearch.filter(items, by: .all, query: query, scope: scope, state: state).map(\.profile.displayName))
    }

    @Test func allScopeFindsIPsAndInstanceType() {
        #expect(names("203.0.113.10") == ["prod-web-01"])
        #expect(names("10.0.12.34") == ["prod-api-01"])
        #expect(names("c6i.xlarge") == ["prod-batch-01"])
        #expect(names("ap-northeast-2c") == ["prod-api-01"])
    }

    @Test func publicIPScopeIgnoresPrivateAddresses() {
        #expect(names("10.0.", scope: .publicIP).isEmpty)
        #expect(names("203.0.113", scope: .publicIP) == ["prod-web-01", "prod-bastion"])
    }

    @Test func privateIPScopeMatchesPrefix() {
        #expect(names("10.1.", scope: .privateIP) == ["dev-web-01", "dev-db-01"])
    }

    @Test func nameScopeDoesNotMatchTags() {
        #expect(names("backend", scope: .name).isEmpty)
        #expect(names("backend", scope: .tag) == ["prod-api-01", "dev-db-01"])
    }

    @Test func instanceIDScope() {
        #expect(names("60003", scope: .instanceID) == ["prod-bastion", "dev-legacy"])
        #expect(names("prod", scope: .instanceID).isEmpty)
    }

    @Test func stateFilters() {
        #expect(names("", state: .running) == ["prod-web-01", "prod-api-01", "prod-bastion", "prod-batch-01", "dev-db-01"])
        #expect(names("", state: .stopped) == ["dev-web-01"])
        #expect(names("dev", state: .running) == ["dev-db-01"])
    }

    @Test func instanceWithoutObservationIsOnlyInAll() {
        let profile = SampleData.profiles(now: fixedDate)[0]
        let unknown = ServerListItem(profile: profile, instance: nil)
        #expect(InstanceStateFilter.all.includes(unknown.instance))
        #expect(!InstanceStateFilter.running.includes(unknown.instance))
        #expect(!ServerSearch.matches(unknown, query: "203", scope: .publicIP))
    }
}
