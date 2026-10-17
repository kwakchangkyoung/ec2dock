import AppKit
import EC2DockCore
import SwiftUI

@main
struct EC2DockApp: App {
    /// `--sample-data`로 실행하면 AWS를 호출하지 않고 샘플 데이터와 Mock을 사용한다.
    private static let usesSampleData = CommandLine.arguments.contains("--sample-data")

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var state: AppState
    @ViewState private var terminals: TerminalSessionStore
    @ViewState private var connections: ConnectionCoordinator

    init() {
        // `swift run`으로 실행할 때도 Dock 아이콘과 키보드 포커스를 갖도록 한다.
        NSApplication.shared.setActivationPolicy(.regular)
        let state = Self.usesSampleData ? AppState.sample() : AppState.live(store: JSONFileStore.applicationSupport)
        let terminals = TerminalSessionStore()
        _state = ViewState(initialValue: state)
        _terminals = ViewState(initialValue: terminals)
        _connections = ViewState(initialValue: ConnectionCoordinator(state: state, terminals: terminals))
    }

    var body: some Scene {
        WindowGroup(Self.usesSampleData ? "EC2Dock (샘플 데이터)" : "EC2Dock") {
            ContentView()
                .environment(state)
                .environment(terminals)
                .environment(connections)
                .frame(minWidth: 1000, minHeight: 600)
                .background(MainWindowAccessor { terminals.mainWindow = $0 })
                .modifier(TerminalAppearanceSync(state: state, terminals: terminals))
                .onAppear {
                    appDelegate.terminals = terminals
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .commands {
            TerminalCommands(state: state, terminals: terminals)
        }

        Settings {
            PreferencesView()
                .environment(state)
                .environment(terminals)
                .frame(width: 560, height: 600)
        }
    }
}

/// 연결 중인 세션이 있으면 앱 종료(⌘Q) 전에 확인한다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var terminals: TerminalSessionStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let count = terminals?.runningSessionCount, count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "연결 중인 터미널 \(count)개가 있습니다"
        alert.informativeText = "EC2Dock을 종료하면 모든 ssh 연결이 끊깁니다."
        alert.addButton(withTitle: "종료")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// 메인 창(NSWindow)을 알려준다. ⌘W 가로채기를 메인 창으로 한정하는 데 쓴다.
private struct MainWindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

/// 설정의 글꼴 크기·테마와 시스템 다크 모드를 열린 터미널에 반영한다.
private struct TerminalAppearanceSync: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let state: AppState
    let terminals: TerminalSessionStore

    func body(content: Content) -> some View {
        let appearance = TerminalAppearance(fontSize: state.preferences.terminalFontSize,
                                            theme: state.preferences.terminalTheme,
                                            systemIsDark: colorScheme == .dark)
        content
            .onChange(of: appearance, initial: true) { _, newValue in
                terminals.appearance = newValue
            }
    }
}

/// 메뉴 막대 "터미널" 메뉴와 단축키 (iTerm2 관례를 따름)
private struct TerminalCommands: Commands {
    let state: AppState
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

            Button(terminals.isFocusMode ? "목록 다시 보기" : "터미널 넓게 보기") { terminals.isFocusMode.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(terminals.activeTab == nil && !terminals.isFocusMode)
            Button("터미널에서 찾기…") { terminals.showFindBar() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(terminals.activeTab == nil)
            Button("다음 찾기") { terminals.find() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(terminals.activeTab == nil || terminals.findQuery.isEmpty)
            Button("이전 찾기") { terminals.find(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(terminals.activeTab == nil || terminals.findQuery.isEmpty)

            Divider()

            Button("글자 크게") { state.preferences.adjustTerminalFontSize(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(state.preferences.terminalFontSize >= AppPreferences.terminalFontSizeRange.upperBound)
            Button("글자 크게 (=)") { state.preferences.adjustTerminalFontSize(by: 1) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(state.preferences.terminalFontSize >= AppPreferences.terminalFontSizeRange.upperBound)
            Button("글자 작게") { state.preferences.adjustTerminalFontSize(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(state.preferences.terminalFontSize <= AppPreferences.terminalFontSizeRange.lowerBound)
            Button("기본 글자 크기") { state.preferences.terminalFontSize = AppPreferences.defaultTerminalFontSize }
                .keyboardShortcut("0", modifiers: [.command, .option])

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
