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
    @ViewState private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            switch sidebarSelection {
            case .servers(let filter):
                DashboardView(filter: filter, searchText: $searchText, searchScope: $searchScope,
                              stateFilter: $stateFilter, selection: $selectedServerID)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380)
            case nil:
                ContentUnavailableView("항목을 선택하세요", systemImage: "sidebar.left")
            }
        } detail: {
            DetailArea(selectedServerID: selectedServerID)
        }
        // 목록에서 서버를 고르면 그 서버 정보를 보여준다. 열린 터미널 탭은 유지된다.
        .onChange(of: selectedServerID) {
            terminals.activeTabID = nil
        }
        // 터미널 집중 모드: 터미널 탭을 보는 동안 사이드바와 목록을 접어 터미널을 넓게 쓴다.
        .onChange(of: terminals.activeTabID) { _, newValue in
            if state.preferences.autoFocusTerminal {
                terminals.isFocusMode = newValue != nil
            }
        }
        .onChange(of: terminals.isFocusMode) { _, focused in
            let target: NavigationSplitViewVisibility = focused ? .detailOnly : .all
            if columnVisibility != target {
                withAnimation(.easeInOut(duration: 0.2)) { columnVisibility = target }
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            // 사용자가 직접 열고 닫은 경우도 집중 모드 상태에 반영한다.
            let focused = visibility == .detailOnly
            if terminals.isFocusMode != focused { terminals.isFocusMode = focused }
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
            accountLabel: state.accountLabel(for:)
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
}
