import EC2DockCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state
    let filter: ServerFilter
    @Binding var searchText: String
    @Binding var searchScope: SearchScope
    @Binding var stateFilter: InstanceStateFilter
    @Binding var selection: String?

    var body: some View {
        let items = state.items(filter: filter, query: searchText, scope: searchScope, state: stateFilter)

        List(items, selection: $selection) { item in
            ServerRowView(item: item)
                .contextMenu {
                    Button(item.profile.isFavorite ? "즐겨찾기 해제" : "즐겨찾기 추가") {
                        state.toggleFavorite(id: item.id)
                    }
                }
        }
        .overlay {
            if items.isEmpty {
                if searchText.isEmpty && stateFilter != .all {
                    ContentUnavailableView("\(stateFilter.displayName) 서버 없음", systemImage: "line.3.horizontal.decrease.circle")
                } else if searchText.isEmpty {
                    ContentUnavailableView(
                        "서버 없음",
                        systemImage: "server.rack",
                        description: Text("Settings에서 조회할 AWS CLI 프로필과 리전을 확인한 뒤 새로고침하세요.")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "이름, 인스턴스 ID, IP, 태그 검색")
        .searchScopes($searchScope) {
            ForEach(SearchScope.allCases) { Text($0.displayName).tag($0) }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Picker("상태", selection: $stateFilter) {
                    ForEach(InstanceStateFilter.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("\(items.count)대")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom) {
            RefreshStatusBar()
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await state.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("AWS에서 인스턴스 정보를 다시 조회합니다")
                .disabled(state.isRefreshing)
            }
        }
        .navigationTitle(title)
    }

    private var title: String {
        switch filter {
        case .all: "All Servers"
        case .favorites: "Favorites"
        case .production: "Production"
        case .development: "Development"
        case .account(let accountID): state.accounts.first { $0.accountID == accountID }?.alias ?? accountID
        }
    }
}

private struct RefreshStatusBar: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    @ViewState private var showsFailures = false
    @ViewState private var showsConflicts = false

    var body: some View {
        HStack(spacing: 6) {
            switch state.refreshStatus {
            case .refreshing:
                ProgressView().controlSize(.small)
                Text("AWS에서 새로고침 중…")
            case .failed(let failures):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(failures.count)개 대상 조회 실패 · 나머지는 캐시 표시\(cacheSuffix)")
                Button("자세히") { showsFailures = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $showsFailures, arrowEdge: .top) {
                        RefreshFailureList(failures: failures) { showsFailures = false }
                            .environment(state)
                            .environment(terminals)
                    }
                // 로그인으로 해결되는 실패가 있으면 바로 로그인할 수 있게 한다.
                if let loginProfile = failures.compactMap(\.loginProfile).first {
                    AWSLoginButton(awsProfile: loginProfile) { await state.refresh() }
                        .buttonStyle(.link)
                }
            case .idle, .succeeded:
                Image(systemName: "clock")
                Text("마지막 조회\(cacheSuffix)")
            }
            Spacer()
            syncIndicator
            if let persistenceError = state.persistenceError {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .help(persistenceError)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var syncIndicator: some View {
        switch state.syncStatus {
        case .disabled:
            EmptyView()
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath.icloud").help("iCloud 동기화 중")
        case .synced:
            Image(systemName: "checkmark.icloud").help(state.syncStatus.summary)
        case .conflicts(let count):
            Button {
                showsConflicts = true
            } label: {
                Label("iCloud 충돌 \(count)건", systemImage: "exclamationmark.icloud")
            }
            .buttonStyle(.link)
            .foregroundStyle(.orange)
            .sheet(isPresented: $showsConflicts) { SyncConflictView() }
        case .failed:
            Image(systemName: "xmark.icloud")
                .foregroundStyle(.orange)
                .help(state.syncStatus.summary)
        }
    }

    private var cacheSuffix: String {
        guard let date = state.lastFetchedAt else { return ": 없음" }
        return ": \(date.formatted(.relative(presentation: .named)))"
    }
}

private struct RefreshFailureList: View {
    @Environment(AppState.self) private var state
    let failures: [RefreshFailure]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(failures) { failure in
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.source).font(.headline)
                    Text(failure.message)
                    if let suggestion = failure.suggestion {
                        Text(suggestion)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let loginProfile = failure.loginProfile {
                        AWSLoginButton(awsProfile: loginProfile, retry: { await state.refresh() }, onOpen: dismiss)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .padding()
        .frame(width: 380, alignment: .leading)
    }
}
