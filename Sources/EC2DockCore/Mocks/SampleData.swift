import Foundation

/// 개발/테스트용 샘플 데이터. 계정 ID와 IP는 모두 가상의 값(RFC 5737 문서용 대역)이다.
public enum SampleData {
    public static let prodAccountID = "111111111111"
    public static let devAccountID = "222222222222"
    public static let seoul = "ap-northeast-2"
    public static let virginia = "us-east-1"

    /// Mock AWS CLI 프로필 → 계정 ID
    public static let awsProfiles = ["acme-prod": prodAccountID, "acme-dev": devAccountID]

    public static let preferences = AppPreferences(
        defaultAWSProfile: "acme-prod",
        enabledAWSProfiles: ["acme-dev", "acme-prod"],
        defaultRegion: seoul,
        regions: [seoul, virginia]
    )

    static let prodWebID = "i-0a1b2c3d4e5f60001"
    static let prodAPIID = "i-0a1b2c3d4e5f60002"
    static let prodBastionID = "i-0a1b2c3d4e5f60003"
    static let prodBatchID = "i-0a1b2c3d4e5f60004"
    static let devWebID = "i-0b1c2d3e4f5a60001"
    static let devDBID = "i-0b1c2d3e4f5a60002"
    static let devLegacyID = "i-0b1c2d3e4f5a60003"
    static let devWorkerID = "i-0b1c2d3e4f5a60004"

    public static var prodBastionProfileID: String {
        ServerProfile.makeID(accountID: prodAccountID, region: seoul, instanceID: prodBastionID)
    }

    public static func profiles(now: Date = Date()) -> [ServerProfile] {
        let created = now.addingTimeInterval(-86_400 * 30)
        func prod(_ region: String, _ id: String, _ name: String) -> ServerProfile {
            ServerProfile(accountID: prodAccountID, accountAlias: "acme-prod", region: region, instanceID: id,
                          displayName: name, environment: "Production", createdAt: created, updatedAt: created)
        }
        func dev(_ region: String, _ id: String, _ name: String) -> ServerProfile {
            ServerProfile(accountID: devAccountID, accountAlias: "acme-dev", region: region, instanceID: id,
                          displayName: name, environment: "Development", createdAt: created, updatedAt: created)
        }

        var web = prod(seoul, prodWebID, "prod-web-01")
        web.groupName = "web"
        web.isFavorite = true

        var api = prod(seoul, prodAPIID, "prod-api-01")
        api.groupName = "api"
        api.connectionType = .bastionSSH
        api.bastionProfileID = prodBastionProfileID

        var bastion = prod(seoul, prodBastionID, "prod-bastion")
        bastion.groupName = "infra"

        var batch = prod(virginia, prodBatchID, "prod-batch-01")
        batch.groupName = "batch"
        batch.connectionType = .ssm

        var devWeb = dev(seoul, devWebID, "dev-web-01")
        devWeb.groupName = "web"

        var devDB = dev(seoul, devDBID, "dev-db-01")
        devDB.groupName = "db"
        devDB.sshUsername = "ubuntu"
        devDB.isFavorite = true

        let legacy = dev(virginia, devLegacyID, "dev-legacy")

        return [web, api, bastion, batch, devWeb, devDB, legacy]
    }

    /// 앱 시작 시 즉시 보여줄 로컬 캐시 (1시간 전 조회 결과)
    public static func cachedInstances(now: Date = Date()) -> [EC2Instance] {
        instances(fetchedAt: now.addingTimeInterval(-3_600), prodWebPublicIP: "203.0.113.10")
            .filter { $0.instanceID != devWorkerID }
    }

    /// Mock AWS가 반환하는 현재 상태.
    /// 캐시와 비교해 prod-web-01의 공인 IP가 바뀌었고, dev-worker-01이 새로 생겼다.
    public static func liveInstances(now: Date = Date()) -> [EC2Instance] {
        instances(fetchedAt: now, prodWebPublicIP: "203.0.113.25")
    }

    private static func instances(fetchedAt: Date, prodWebPublicIP: String) -> [EC2Instance] {
        func tags(_ name: String, _ env: String, _ extra: [String: String] = [:]) -> [String: String] {
            ["Name": name, "Environment": env].merging(extra) { $1 }
        }
        return [
            EC2Instance(accountID: prodAccountID, region: seoul, instanceID: prodWebID, state: "running",
                        publicIPAddress: prodWebPublicIP, privateIPAddress: "10.0.1.10",
                        availabilityZone: "ap-northeast-2a", instanceType: "t3.medium", vpcID: "vpc-0a1b2c3d4e5f60001",
                        tags: tags("prod-web-01", "Production", ["Team": "platform"]), lastFetchedAt: fetchedAt),
            EC2Instance(accountID: prodAccountID, region: seoul, instanceID: prodAPIID, state: "running",
                        privateIPAddress: "10.0.12.34",
                        availabilityZone: "ap-northeast-2c", instanceType: "m6i.large", vpcID: "vpc-0a1b2c3d4e5f60001",
                        tags: tags("prod-api-01", "Production", ["Team": "backend"]), lastFetchedAt: fetchedAt),
            EC2Instance(accountID: prodAccountID, region: seoul, instanceID: prodBastionID, state: "running",
                        publicIPAddress: "203.0.113.5", privateIPAddress: "10.0.0.5",
                        availabilityZone: "ap-northeast-2a", instanceType: "t3.micro", vpcID: "vpc-0a1b2c3d4e5f60001",
                        tags: tags("prod-bastion", "Production", ["Role": "bastion"]), lastFetchedAt: fetchedAt),
            EC2Instance(accountID: prodAccountID, region: virginia, instanceID: prodBatchID, state: "running",
                        privateIPAddress: "10.20.3.40",
                        availabilityZone: "us-east-1b", instanceType: "c6i.xlarge", vpcID: "vpc-0a1b2c3d4e5f60002",
                        tags: tags("prod-batch-01", "Production", ["Team": "data"]), lastFetchedAt: fetchedAt),
            EC2Instance(accountID: devAccountID, region: seoul, instanceID: devWebID, state: "stopped",
                        privateIPAddress: "10.1.1.10",
                        availabilityZone: "ap-northeast-2b", instanceType: "t3.small", vpcID: "vpc-0b1c2d3e4f5a60001",
                        tags: tags("dev-web-01", "Development"), lastFetchedAt: fetchedAt),
            EC2Instance(accountID: devAccountID, region: seoul, instanceID: devDBID, state: "running",
                        publicIPAddress: "198.51.100.20", privateIPAddress: "10.1.2.20",
                        availabilityZone: "ap-northeast-2a", instanceType: "r6g.large", vpcID: "vpc-0b1c2d3e4f5a60001",
                        tags: tags("dev-db-01", "Development", ["Team": "backend"]), lastFetchedAt: fetchedAt),
            EC2Instance(accountID: devAccountID, region: virginia, instanceID: devLegacyID, state: "terminated",
                        availabilityZone: "us-east-1a", instanceType: "t2.micro", vpcID: "vpc-0b1c2d3e4f5a60002",
                        tags: tags("dev-legacy", "Development"), lastFetchedAt: fetchedAt),
            EC2Instance(accountID: devAccountID, region: seoul, instanceID: devWorkerID, state: "running",
                        publicIPAddress: "198.51.100.30", privateIPAddress: "10.1.3.30",
                        availabilityZone: "ap-northeast-2c", instanceType: "t3.medium", vpcID: "vpc-0b1c2d3e4f5a60001",
                        tags: tags("dev-worker-01", "Development", ["Team": "data"]), lastFetchedAt: fetchedAt),
        ]
    }
}
