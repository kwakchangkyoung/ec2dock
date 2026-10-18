import EC2DockCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @Environment(ConnectionCoordinator.self) private var connections
    let filter: ServerFilter
    @Binding var searchText: String
    @Binding var searchScope: SearchScope
    @Binding var stateFilter: InstanceStateFilter
    @Binding var selection: String?
    @ViewState private var pendingDeleteID: String?
    /// 시작 안내 화면에서 연다. 로그인 중 서버가 생겨 안내 화면이 사라져도 시트가 닫히지 않도록 목록 화면이 띄운다.
    @ViewState private var showsAddAccount = false

    var body: some View {
        let preferences = state.preferences
        let items = ServerSearch.sorted(
            state.items(filter: filter, query: searchText, scope: searchScope, state: stateFilter),
            by: preferences.listSort, accountLabel: state.accountLabel(for:))
        let sections = ServerSearch.sections(items, by: preferences.listGrouping, accountLabel: state.accountLabel(for:))

        List(selection: $selection) {
            ForEach(sections) { section in
                if section.title.isEmpty {
                    rows(section.items, density: preferences.listDensity)
                } else {
                    Section("\(section.title) · \(section.items.count)") {
                        rows(section.items, density: preferences.listDensity)
                    }
                }
            }
        }
        // 더블클릭·Return: 기본 터미널로 접속 / 우클릭: 서버 동작 메뉴
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let item = state.item(id: id) {
                contextMenu(for: item)
            }
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            Task { await connections.connect(profileID: id, terminal: nil, source: .list) }
        }
        .overlay {
            if items.isEmpty {
                emptyState
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "이름, 인스턴스 ID, IP, 태그 검색")
        .searchScopes($searchScope) {
            ForEach(SearchScope.allCases) { Text($0.displayName).tag($0) }
        }
        .safeAreaInset(edge: .top) {
            ListHeaderBar(stateFilter: $stateFilter, count: items.count)
        }
        .safeAreaInset(edge: .bottom) {
            RefreshStatusBar()
        }
        .toolbar {
            ToolbarItemGroup {
                StatusIndicators()
                Button {
                    Task { await state.refresh() }
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .help("AWS에서 인스턴스 정보를 다시 조회합니다 (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.isRefreshing)
            }
        }
        .navigationTitle(title)
        .alert(
            "서버 프로필을 삭제할까요?",
            isPresented: Binding(get: { pendingDeleteID != nil }, set: { if !$0 { pendingDeleteID = nil } }),
            presenting: pendingDeleteID
        ) { id in
            Button("삭제", role: .destructive) {
                if selection == id { selection = nil }
                state.deleteProfile(id: id)
            }
            Button("취소", role: .cancel) {}
        } message: { id in
            let name = state.profile(id: id)?.displayName ?? "선택한 서버"
            Text("'\(name)' 프로필을 삭제합니다. 이 Mac의 캐시와 접속 설정이 제거되며, iCloud 동기화가 켜져 있으면 다른 Mac에서도 삭제됩니다. 새로고침해도 다시 추가되지 않으며, 설정 > 일반에서 복원할 수 있습니다.")
        }
        .sheet(isPresented: $showsAddAccount) { AddAWSAccountView() }
    }

    private func rows(_ items: [ServerListItem], density: ServerListDensity) -> some View {
        ForEach(items) { item in
            ServerRowView(item: item, density: density)
                .tag(item.id)
        }
    }

    @ViewBuilder
    private func contextMenu(for item: ServerListItem) -> some View {
        let id = item.id
        let blocked = state.connectionBlockingReason(for: id) != nil
        Button("접속 (\(connections.defaultTerminal(for: id).displayName))") {
            Task { await connections.connect(profileID: id, terminal: nil, source: .list) }
        }
        .disabled(blocked)
        Menu("다른 터미널로 접속") {
            ForEach(TerminalApp.allCases) { app in
                Button(app.displayName) {
                    Task { await connections.connect(profileID: id, terminal: app, source: .list) }
                }
            }
        }
        .disabled(blocked)
        Divider()
        Button("접속 설정…") { connections.editingProfileID = id }
        Button("다시 조회") { Task { await connections.refreshInstance(profileID: id) } }
        Divider()
        if let ip = item.instance?.publicIPAddress {
            Button("공인 IP 복사 (\(ip))") { ConnectionCoordinator.copy(ip) }
        }
        if let ip = item.instance?.privateIPAddress {
            Button("사설 IP 복사 (\(ip))") { ConnectionCoordinator.copy(ip) }
        }
        Button("인스턴스 ID 복사") { ConnectionCoordinator.copy(item.profile.instanceID) }
        Button("SSH 명령 복사") { connections.copyCommand(profileID: id, source: .list) }
            .disabled(blocked)
        Divider()
        Button(item.profile.isFavorite ? "즐겨찾기 해제" : "즐겨찾기 추가") {
            state.toggleFavorite(id: id)
        }
        Button("서버 프로필 삭제…", role: .destructive) {
            pendingDeleteID = id
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if state.profiles.isEmpty && searchText.isEmpty {
            // 서버가 하나도 없으면 시작 체크리스트를 보여준다.
            GettingStartedView(showsAddAccount: $showsAddAccount)
        } else if searchText.isEmpty && stateFilter != .all {
            ContentUnavailableView("\(stateFilter.displayName) 서버 없음", systemImage: "line.3.horizontal.decrease.circle")
        } else if searchText.isEmpty {
            ContentUnavailableView("이 분류에 서버가 없습니다", systemImage: "server.rack")
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private var title: String {
        switch filter {
        case .all: "전체 서버"
        case .favorites: "즐겨찾기"
        case .production: "운영 서버"
        case .development: "개발 서버"
        case .account(let accountID): state.accounts.first { $0.accountID == accountID }?.alias ?? accountID
        }
    }
}

// MARK: - 목록 머리줄 (상태 필터 · 보기 옵션 · 개수)

private struct ListHeaderBar: View {
    @Environment(AppState.self) private var state
    @Binding var stateFilter: InstanceStateFilter
    let count: Int

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 8) {
            Picker("상태", selection: $stateFilter) {
                ForEach(InstanceStateFilter.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Text("\(count)대")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Menu {
                Picker("정렬", selection: $state.preferences.listSort) {
                    ForEach(ServerSortOrder.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("묶기", selection: $state.preferences.listGrouping) {
                    ForEach(ServerGrouping.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("보기", selection: $state.preferences.listDensity) {
                    ForEach(ServerListDensity.allCases) { Text($0.displayName).tag($0) }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("정렬 · 묶기 · 보기 밀도")
            .accessibilityLabel("목록 보기 옵션")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - 하단 상태 표시줄 (조회 상태 · 진행률)

private struct RefreshStatusBar: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    @ViewState private var showsFailures = false

    var body: some View {
        HStack(spacing: 6) {
            switch state.refreshStatus {
            case .refreshing:
                if let progress = state.refreshProgress, progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .progressViewStyle(.linear)
                        .frame(width: 70)
                    Text("AWS 조회 중 \(progress.completed)/\(progress.total)")
                        .monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                    Text("AWS 계정 확인 중…")
                }
            case .failed(let failures):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(failures.count)곳 조회 실패")
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
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var cacheSuffix: String {
        guard let date = state.lastFetchedAt else { return ": 없음" }
        return ": \(date.formatted(.relative(presentation: .named)))"
    }
}

// MARK: - 툴바 상태 아이콘 (iCloud 동기화 · 저장 오류)

private struct StatusIndicators: View {
    @Environment(AppState.self) private var state
    @ViewState private var showsConflicts = false

    var body: some View {
        switch state.syncStatus {
        case .disabled:
            EmptyView()
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath.icloud")
                .help("iCloud 동기화 중")
                .accessibilityLabel("iCloud 동기화 중")
        case .synced:
            Image(systemName: "checkmark.icloud")
                .foregroundStyle(.secondary)
                .help(state.syncStatus.summary)
                .accessibilityLabel(state.syncStatus.summary)
        case .conflicts(let count):
            Button {
                showsConflicts = true
            } label: {
                Label("iCloud 충돌 \(count)건", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            }
            .help("iCloud 동기화 충돌 \(count)건 해결")
            .sheet(isPresented: $showsConflicts) { SyncConflictView() }
        case .failed:
            Image(systemName: "xmark.icloud")
                .foregroundStyle(.orange)
                .help(state.syncStatus.summary)
                .accessibilityLabel(state.syncStatus.summary)
        }
        if let persistenceError = state.persistenceError {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
                .help(persistenceError)
                .accessibilityLabel(persistenceError)
        }
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

// MARK: - 시작 체크리스트

/// 서버가 하나도 없을 때: AWS CLI → 계정 → 조회 프로필 → 리전 → 새로고침 순서로 안내한다.
private struct GettingStartedView: View {
    @Environment(AppState.self) private var state
    @Binding var showsAddAccount: Bool

    var body: some View {
        let cliReady = !state.isAWSCLIMissing
        let hasProfiles = !state.availableAWSProfiles.isEmpty
        let scanProfiles = state.preferences.profilesToScan.filter(state.availableAWSProfiles.contains)
        let ready = cliReady && hasProfiles && !scanProfiles.isEmpty

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("EC2Dock 시작하기").font(.title2.weight(.semibold))
                    Text("AWS 계정의 EC2 서버를 가져오려면 아래 단계를 차례로 확인하세요.")
                        .foregroundStyle(.secondary)
                }

                step(1, "AWS CLI 설치", done: cliReady,
                     detail: cliReady ? "AWS CLI를 찾았습니다." : "터미널에서 brew install awscli 로 설치한 뒤 앱을 다시 여세요.") {
                    if !cliReady {
                        Button("설치 명령 복사") { ConnectionCoordinator.copy("brew install awscli") }
                    }
                }
                step(2, "AWS 계정 연결", done: hasProfiles,
                     detail: hasProfiles ? "AWS CLI 프로필 \(state.availableAWSProfiles.count)개" : "브라우저 로그인으로 계정을 추가합니다.") {
                    Button(hasProfiles ? "계정 더 추가…" : "AWS 계정 추가…") { showsAddAccount = true }
                        .disabled(!cliReady)
                }
                step(3, "조회할 프로필 선택", done: !scanProfiles.isEmpty,
                     detail: scanProfiles.isEmpty ? "설정에서 조회할 프로필을 켜세요." : scanProfiles.joined(separator: ", ")) {
                    SettingsLink { Text("설정 열기") }
                }
                step(4, "조회 리전 확인", done: !state.preferences.regions.isEmpty,
                     detail: state.preferences.regions.map(AWSRegions.displayName(for:)).joined(separator: ", ")) {
                    SettingsLink { Text("리전 바꾸기") }
                }
                step(5, "서버 목록 가져오기", done: false, detail: "준비가 되면 새로고침하세요 (⌘R).") {
                    Button("새로고침") { Task { await state.refresh() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!ready || state.isRefreshing)
                }
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    private func step<Actions: View>(_ number: Int, _ title: String, done: Bool, detail: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title3)
                .foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityLabel(done ? "완료" : "\(number)단계")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                HStack { actions() }.padding(.top, 2)
            }
        }
    }
}
