import Foundation
import Sparkle

/// Sparkle 자동 업데이트. 업데이트 파일은 EdDSA 서명(Info.plist의 SUPublicEDKey)을 확인한 뒤에만 설치한다.
/// 앱 번들(.app)로 실행할 때만 켠다: `swift run`으로 실행하면 업데이트 주소와 공개 키가 없다.
@MainActor @Observable
final class AppUpdater {
    private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// 업데이트 확인 중이면 false (메뉴를 잠시 끈다)
    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    /// 새 버전을 미리 내려받아 두고 앱을 종료할 때 설치한다.
    var automaticallyDownloadsUpdates: Bool {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    var isAvailable: Bool { controller != nil }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 빌드"
    }

    init() {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              bundle.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else {
            controller = nil
            automaticallyChecksForUpdates = false
            automaticallyDownloadsUpdates = false
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            MainActor.assumeIsolated { self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
