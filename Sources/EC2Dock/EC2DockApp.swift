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
        .commands {
            TerminalCommands(terminals: terminals)
        }

        Settings {
            PreferencesView()
                .environment(state)
                .frame(width: 520, height: 640)
        }
    }
}

/// 메뉴 막대 "터미널" 메뉴와 단축키 (iTerm2 관례를 따름)
private struct TerminalCommands: Commands {
    let terminals: TerminalSessionStore

    var body: some Commands {
        CommandMenu("터미널") {
            Button("좌우로 분할") { terminals.requestSplit(axis: .horizontal) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!terminals.canSplit)
            Button("위아래로 분할") { terminals.requestSplit(axis: .vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!terminals.canSplit)
            Button("이 칸 닫기") { terminals.requestCloseFocusedPane() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(terminals.activeTab == nil)

            Divider()

            Button("다음 칸") { terminals.focusAdjacentPane(offset: 1) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!hasSplitPanes)
            Button("이전 칸") { terminals.focusAdjacentPane(offset: -1) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!hasSplitPanes)

            Divider()

            // 터미널 탭이 없을 때는 꺼 두어 검색창 등에서 ⌘←/⌘→(줄 처음/끝 이동)를 가로채지 않게 한다.
            Button("다음 탭") { terminals.selectAdjacentTab(offset: 1) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(terminals.tabs.isEmpty)
            Button("이전 탭") { terminals.selectAdjacentTab(offset: -1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(terminals.tabs.isEmpty)
            Button("다음 탭 (대체 키)") { terminals.selectAdjacentTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(terminals.tabs.isEmpty)
            Button("이전 탭 (대체 키)") { terminals.selectAdjacentTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(terminals.tabs.isEmpty)

            Divider()

            Button("서버 정보") { terminals.selectTab(number: 0) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(terminals.tabs.isEmpty)
            ForEach(1...9, id: \.self) { number in
                Button("터미널 탭 \(number)") { terminals.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                    .disabled(terminals.tabs.count < number)
            }
        }
    }

    private var hasSplitPanes: Bool {
        (terminals.activeTab?.root.paneIDs.count ?? 0) > 1
    }
}
