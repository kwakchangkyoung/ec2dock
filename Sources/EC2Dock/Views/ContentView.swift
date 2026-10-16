import EC2DockCore
import SwiftUI

enum SidebarItem: Hashable {
    case servers(ServerFilter)
    case settings
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    @ViewState private var sidebarSelection: SidebarItem? = .servers(.all)
    @ViewState private var selectedServerID: String?
    @ViewState private var searchText = ""
    @ViewState private var searchScope: SearchScope = .all
    @ViewState private var stateFilter: InstanceStateFilter = .all

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            switch sidebarSelection {
            case .servers(let filter):
                DashboardView(filter: filter, searchText: $searchText, searchScope: $searchScope,
                              stateFilter: $stateFilter, selection: $selectedServerID)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380)
            case .settings:
                PreferencesView()
            case nil:
                ContentUnavailableView("항목을 선택하세요", systemImage: "sidebar.left")
            }
        } detail: {
            DetailArea(selectedServerID: selectedServerID)
        }
        // 목록에서 서버를 고르면 그 서버 정보를 보여준다. 열린 터미널 탭은 유지된다.
        .onChange(of: selectedServerID) {
            terminals.activeSessionID = nil
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
    }
}
