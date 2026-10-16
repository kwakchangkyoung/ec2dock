import AppKit
import EC2DockCore
import SwiftUI

@main
struct EC2DockApp: App {
    /// `--sample-data`로 실행하면 AWS를 호출하지 않고 샘플 데이터와 Mock을 사용한다.
    private static let usesSampleData = CommandLine.arguments.contains("--sample-data")

    @ViewState private var state = usesSampleData ? AppState.sample() : AppState.live(store: JSONFileStore.applicationSupport)
    @ViewState private var terminals = TerminalSessionStore()

    init() {
        // `swift run`으로 실행할 때도 Dock 아이콘과 키보드 포커스를 갖도록 한다.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup(Self.usesSampleData ? "EC2Dock (Sample Data)" : "EC2Dock") {
            ContentView()
                .environment(state)
                .environment(terminals)
                .frame(minWidth: 1000, minHeight: 600)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }

        Settings {
            PreferencesView()
                .environment(state)
                .frame(width: 520, height: 640)
        }
    }
}
