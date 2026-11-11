import EC2DockCore
import SwiftUI

enum SidebarItem: Hashable {
    case servers(ServerFilter)
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    @Environment(ConnectionCoordinator.self) private var connections
    @ViewState private var sidebarSelection: SidebarItem? = .servers(.all)
    @ViewState private var selectedServerID: String?
    @ViewState private var searchText = ""
    @ViewState private var searchScope: SearchScope = .all
    @ViewState private var stateFilter: InstanceStateFilter = .all
    /// 사이드바 표시 여부 (.all: 보임, .detailOnly: 숨김). 목록은 넓게 보기 상태에 따라 이 화면이 직접 숨긴다.
    @ViewState private var columnVisibility: NavigationSplitViewVisibility = .all
    /// 넓게 보기를 끌 때 돌아갈 사이드바 상태 (사용자가 사이드바를 숨겨 둔 경우 유지한다)
    @ViewState private var visibilityBeforeFocus: NavigationSplitViewVisibility = .all

    var body: some View {
        // 3칸 NavigationSplitView의 .detailOnly는 macOS 27에서 반영되지 않고 모든 칸을 펼친다
        // (숨긴 사이드바가 다시 나타남). 그래서 사이드바만 분할 보기로 두고, 목록은 직접 숨긴다.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            HSplitView {
                if !terminals.isFocusMode {
                    serverList
                        .frame(minWidth: 320, idealWidth: 380, maxWidth: 600, maxHeight: .infinity)
                }
                DetailArea(selectedServerID: selectedServerID)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 목록에서 서버를 고르면 그 서버 정보를 보여준다. 열린 터미널 탭은 유지된다.
        .onChange(of: selectedServerID) {
            terminals.activeTabID = nil
        }
        // 넓게 보기는 사용자가 버튼(⇧⌘F)으로만 켜고 끈다. 탭을 옮겨도 그대로 유지하고,
        // 탭이 모두 닫히면 끌 버튼이 없어지므로 끈다.
        .onChange(of: terminals.tabs.isEmpty) { _, isEmpty in
            if isEmpty { terminals.isFocusMode = false }
        }
        // 넓게 보기: 목록(위 HSplitView)과 사이드바를 접는다. 끌 때는 들어가기 전 사이드바 상태로 돌아간다.
        .onChange(of: terminals.isFocusMode) { _, focused in
            if focused { visibilityBeforeFocus = columnVisibility }
            let target: NavigationSplitViewVisibility = focused ? .detailOnly : visibilityBeforeFocus
            if columnVisibility != target {
                withAnimation(.easeInOut(duration: 0.2)) { columnVisibility = target }
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            // 넓게 보기 중에 사용자가 사이드바를 열면 넓게 보기를 끄고 목록도 다시 보여준다.
            // SwiftUI가 자동 값(.automatic)을 써넣는 경우는 사용자 조작이 아니므로 무시한다.
            guard visibility != .automatic, terminals.isFocusMode, visibility != .detailOnly else { return }
            visibilityBeforeFocus = visibility
            terminals.isFocusMode = false
        }
        // 창을 닫았다 다시 열면 화면 구성이 처음 값으로 돌아오므로 넓게 보기 상태에 맞춘다.
        .onAppear {
            if terminals.isFocusMode { columnVisibility = .detailOnly }
        }
        // 시작 시에는 AWS를 호출하지 않고 캐시만 보여준다(재조회는 버튼으로).
        // 로컬 AWS CLI 프로필 목록만 읽어 둔다. 자동 새로고침은 설정에서 켠 경우에만 동작한다.
        .task(id: state.preferences.autoRefreshIntervalMinutes) {
            await state.reloadAWSProfiles()
            let minutes = state.preferences.autoRefreshIntervalMinutes
            guard minutes > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled else { return }
                await state.refresh()
            }
        }
        // 프로필이 바뀌면 잠시 기다렸다가 동기화한다 (연속 변경은 한 번으로 묶인다). 앱 시작 시에도 한 번 실행된다.
        .task(id: state.profiles) {
            guard state.preferences.iCloudSyncEnabled else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await state.syncNow()
        }
        // 다른 Mac의 변경을 받아오기 위해 주기적으로 확인한다.
        .task(id: state.preferences.iCloudSyncEnabled) {
            await state.refreshSyncAvailability()
            while state.preferences.iCloudSyncEnabled && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await state.syncNow()
            }
        }
        // 목록·상세 화면이 함께 쓰는 확인 창과 시트
        .productionConfirmation(
            target: Binding(get: { connections.pendingConfirmation?.target },
                            set: { if $0 == nil { connections.pendingConfirmation = nil } }),
            accountLabel: state.accountLabel(for:),
            title: confirmationText.title,
            confirmLabel: confirmationText.button
        ) { _ in
            connections.confirmPending()
        }
        .sheet(isPresented: Binding(get: { connections.editingProfileID != nil },
                                    set: { if !$0 { connections.editingProfileID = nil } })) {
            if let id = connections.editingProfileID, let profile = state.profile(id: id) {
                ConnectionSettingsView(profile: profile, settings: state.localSettings(for: id))
            }
        }
        .alert(connections.listAlert?.title ?? "",
               isPresented: Binding(get: { connections.listAlert != nil }, set: { if !$0 { connections.listAlert = nil } }),
               presenting: connections.listAlert) { alert in
            if let attempt = alert.attempt {
                if attempt.terminal != .embedded {
                    Button("내장 터미널로 열기") {
                        Task { await connections.perform(attempt.target, confirmed: attempt.confirmed, terminal: .embedded, source: .list) }
                    }
                }
                Button("명령 복사") { connections.copyCommand(for: attempt) }
            }
            Button("접속 설정 열기") { connections.editingProfileID = alert.profileID }
            Button("닫기", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }

    @ViewBuilder
    private var serverList: some View {
        switch sidebarSelection {
        case .servers(let filter):
            DashboardView(filter: filter, searchText: $searchText, searchScope: $searchScope,
                          stateFilter: $stateFilter, selection: $selectedServerID)
        case nil:
            ContentUnavailableView("항목을 선택하세요", systemImage: "sidebar.left")
        }
    }

    /// Production 확인 창의 제목과 확인 버튼 (접속·명령 복사·파일 열기)
    private var confirmationText: (title: String, button: String) {
        switch connections.pendingConfirmation?.action {
        case .copyCommand: ("Production 서버 접속 명령을 복사합니다", "복사")
        case .openFiles: ("Production 서버 파일을 엽니다", "열기")
        case .connect, nil: ("Production 서버에 접속합니다", "접속")
        }
    }
}

