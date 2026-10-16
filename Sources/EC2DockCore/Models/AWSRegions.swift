import Foundation

/// 설정 화면 선택지용 AWS 상용 리전 목록.
/// 목록에 없는 리전은 코드로 직접 추가할 수 있으므로 완전한 목록일 필요는 없다.
public enum AWSRegions {
    public static let known: [(code: String, name: String)] = [
        ("ap-northeast-2", "서울"),
        ("ap-northeast-1", "도쿄"),
        ("ap-northeast-3", "오사카"),
        ("ap-east-1", "홍콩"),
        ("ap-east-2", "타이베이"),
        ("ap-southeast-1", "싱가포르"),
        ("ap-southeast-2", "시드니"),
        ("ap-southeast-3", "자카르타"),
        ("ap-southeast-4", "멜버른"),
        ("ap-southeast-5", "말레이시아"),
        ("ap-southeast-7", "태국"),
        ("ap-south-1", "뭄바이"),
        ("ap-south-2", "하이데라바드"),
        ("us-east-1", "버지니아 북부"),
        ("us-east-2", "오하이오"),
        ("us-west-1", "캘리포니아 북부"),
        ("us-west-2", "오레곤"),
        ("ca-central-1", "캐나다 중부"),
        ("ca-west-1", "캘거리"),
        ("mx-central-1", "멕시코"),
        ("sa-east-1", "상파울루"),
        ("eu-central-1", "프랑크푸르트"),
        ("eu-central-2", "취리히"),
        ("eu-west-1", "아일랜드"),
        ("eu-west-2", "런던"),
        ("eu-west-3", "파리"),
        ("eu-south-1", "밀라노"),
        ("eu-south-2", "스페인"),
        ("eu-north-1", "스톡홀름"),
        ("il-central-1", "텔아비브"),
        ("me-south-1", "바레인"),
        ("me-central-1", "UAE"),
        ("af-south-1", "케이프타운"),
    ]

    /// 예: "ap-northeast-2 (서울)". 목록에 없으면 코드만 반환한다.
    public static func displayName(for code: String) -> String {
        guard let name = known.first(where: { $0.code == code })?.name else { return code }
        return "\(code) (\(name))"
    }
}
