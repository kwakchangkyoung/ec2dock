// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EC2Dock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EC2Dock", targets: ["EC2Dock"]),
        .library(name: "EC2DockCore", targets: ["EC2DockCore"]),
    ],
    dependencies: [
        // 내장 터미널 에뮬레이터 (MIT). 검증된 릴리스로 고정한다.
        // 1.12.0부터 Metal 셰이더가 포함되어 Xcode의 metal 컴파일러가 필요하므로,
        // Command Line Tools로도 빌드되는 마지막 버전을 사용한다.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2"),
        // 앱 자동 업데이트 (MIT). 미리 빌드된 프레임워크라 Command Line Tools로도 쓸 수 있다.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // 모델, 서비스 프로토콜, Mock, 앱 상태 (UI 및 외부 의존성 없음)
        .target(name: "EC2DockCore"),
        // SwiftUI 화면
        .executableTarget(
            name: "EC2Dock",
            dependencies: [
                "EC2DockCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(name: "EC2DockCoreTests", dependencies: ["EC2DockCore"]),
    ]
)
