import AppKit
import EC2DockCore
import SwiftUI

struct ServerDetailView: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    @Environment(ConnectionCoordinator.self) private var connections
    let item: ServerListItem

    @ViewState private var copiedCommand = false
    @ViewState private var isRefreshingInstance = false
    @ViewState private var refreshError: ConnectionError?
    @ViewState private var confirmsDeletion = false

    private var profile: ServerProfile { item.profile }

    var body: some View {
        Form {
            header
            connectSection
            awsSection
            profileSection
            localSection
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
        .navigationTitle(profile.displayName)
        .toolbar {
            ToolbarItem {
                Button {
                    connections.editingProfileID = profile.id
                } label: {
                    Label("접속 설정 편집", systemImage: "slider.horizontal.3")
                }
                .help("접속 설정 편집 (접속 방식, Bastion, SSH 사용자·포트·키, 터미널)")
            }
            ToolbarItem {
                Button(role: .destructive) {
                    confirmsDeletion = true
                } label: {
                    Label("서버 삭제", systemImage: "trash")
                }
                .help("이 서버 프로필을 삭제합니다")
            }
        }
        .alert("서버 프로필을 삭제할까요?", isPresented: $confirmsDeletion) {
            Button("삭제", role: .destructive) {
                state.deleteProfile(id: profile.id)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("'\(profile.displayName)' 프로필을 삭제합니다. 이 Mac의 캐시와 접속 설정이 제거되며, iCloud 동기화가 켜져 있으면 다른 Mac에서도 삭제됩니다. 새로고침해도 다시 추가되지 않으며, 설정 > 일반에서 복원할 수 있습니다.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        Section {
            HStack(spacing: 10) {
                FavoriteButton(isFavorite: profile.isFavorite) {
                    state.toggleFavorite(id: profile.id)
                }
                .font(.title2)
                Text(profile.displayName)
                    .font(.title2.weight(.semibold))
                StateBadge(state: item.stateLabel)
                if !profile.environment.isEmpty {
                    EnvironmentTag(environment: profile.environment, isProduction: profile.isProduction)
                }
            }
        }
    }

    private var connectSection: some View {
        Section {
            let blockingReason = state.connectionBlockingReason(for: profile.id)
            let isConnecting = connections.connectingIDs.contains(profile.id)
            let feedback = connections.feedback[profile.id]
            HStack {
                // 기본 클릭은 서버 설정의 터미널로 열고, 화살표 메뉴로 다른 방식을 고를 수 있다.
                Menu {
                    ForEach(TerminalApp.allCases) { app in
                        Button("\(app.displayName)로 열기") {
                            Task { await connections.connect(profileID: profile.id, terminal: app, source: .detail) }
                        }
                    }
                } label: {
                    Label("접속", systemImage: "terminal")
                        .frame(minWidth: 100)
                } primaryAction: {
                    Task { await connections.connect(profileID: profile.id, terminal: nil, source: .detail) }
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fixedSize()
                .disabled(blockingReason != nil || isConnecting)
                .help("클릭: \(defaultTerminal.displayName)로 열기 · 화살표: 열기 방식 선택 · 목록에서 더블클릭/Return으로도 접속")

                if isConnecting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("\(profile.connectionType.displayName) · \(defaultTerminal.displayName)")
                    .foregroundStyle(.secondary)
                Button("접속 설정…") { connections.editingProfileID = profile.id }
                    .help("접속 방식, Bastion, SSH 사용자·포트·키, 터미널을 설정합니다")
            }

            let openSessions = terminals.sessions(for: profile.id)
            if !openSessions.isEmpty {
                HStack {
                    Label("이 서버에 열린 내장 터미널 \(openSessions.count)개", systemImage: "terminal")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("터미널로 이동") {
                        if let last = openSessions.last { terminals.show(paneID: last.id) }
                    }
                }
            }

            if case .failure(let error) = feedback?.kind {
                errorBlock(error, attempt: feedback?.attempt)
            } else if let blockingReason {
                errorBlock(blockingReason, attempt: nil)
            } else if case .success(let message) = feedback?.kind {
                Label(message, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        } footer: {
            Text(cacheFooter)
        }
    }

    @ViewBuilder
    private func errorBlock(_ error: ConnectionError, attempt: ConnectionCoordinator.Attempt?) -> some View {
        ErrorGuidance(error: error)
        if Self.isFixedInSettings(error) {
            Button("접속 설정 열기") { connections.editingProfileID = profile.id }
        }
        if let attempt {
            fallbackActions(for: attempt)
        }
    }

    private func fallbackActions(for attempt: ConnectionCoordinator.Attempt) -> some View {
        HStack {
            if attempt.terminal != .embedded {
                Button("내장 터미널로 열기") {
                    Task { await connections.perform(attempt.target, confirmed: attempt.confirmed, terminal: .embedded, source: .detail) }
                }
            }
            if attempt.terminal != .terminal {
                Button("Terminal로 열기") {
                    Task { await connections.perform(attempt.target, confirmed: attempt.confirmed, terminal: .terminal, source: .detail) }
                }
            }
            Button(copiedCommand ? "복사됨" : "명령 복사") {
                if connections.copyCommand(for: attempt) { flashCopied() }
            }
            .help("SSH 명령을 클립보드에 복사합니다. 터미널에 붙여 넣어 직접 실행하세요.")
        }
        .disabled(connections.connectingIDs.contains(profile.id))
    }

    private var awsSection: some View {
        Section {
            copyableRow("인스턴스 ID", profile.instanceID)
            if let instance = item.instance {
                LabeledContent("상태", value: instance.state)
                copyableRow("공인 IP", instance.publicIPAddress)
                copyableRow("사설 IP", instance.privateIPAddress)
                LabeledContent("가용 영역", value: instance.availabilityZone ?? "-")
                LabeledContent("인스턴스 유형", value: instance.instanceType ?? "-")
                LabeledContent("마지막 조회", value: instance.lastFetchedAt.formatted(date: .abbreviated, time: .standard))
                if !instance.tags.isEmpty {
                    LabeledContent("태그") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(instance.tags.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                Text("\(key) = \(value)").font(.callout.monospaced())
                            }
                        }
                    }
                }
            } else {
                Text("이 Mac에 조회된 정보가 없습니다. \"다시 조회\"를 누르세요.").foregroundStyle(.secondary)
            }
            if let refreshError {
                Text([refreshError.errorDescription, refreshError.recoverySuggestion].compactMap { $0 }.joined(separator: " "))
                    .font(.callout)
                    .foregroundStyle(.orange)
                if let loginProfile = refreshError.loginProfile {
                    // 로그인 탭이 열리면 이 화면은 사라지므로, 재조회는 화면 상태가 아닌 AppState에 직접 요청한다.
                    AWSLoginButton(awsProfile: loginProfile) { [state, id = profile.id] in
                        _ = try? await state.refreshInstance(id: id)
                    }
                }
            }
        } header: {
            HStack {
                Label("AWS에서 조회한 정보 (캐시)", systemImage: "cloud")
                Spacer()
                if isRefreshingInstance {
                    ProgressView().controlSize(.small)
                }
                Button("다시 조회") { Task { await refreshInstance() } }
                    .disabled(isRefreshingInstance)
                    .help("AWS에서 이 서버의 최신 상태와 IP를 가져옵니다")
            }
        }
    }

    /// 접속에 쓸 IP가 언제 조회된 값인지 알려준다.
    private var cacheFooter: String {
        let hostKeyNote = "IP가 바뀌었다면 호스트 키 검증(인스턴스 ID 기준)이 접속을 중단합니다. 그때는 \"다시 조회\"를 누르세요."
        guard let fetched = item.instance?.lastFetchedAt else { return hostKeyNote }
        return "접속하면 \(fetched.formatted(.relative(presentation: .named)))에 조회한 IP로 바로 연결합니다. " + hostKeyNote
    }

    private var profileSection: some View {
        Section {
            LabeledContent("표시 이름", value: profile.displayName)
            LabeledContent("계정", value: "\(state.accountLabel(for: profile.accountID)) (\(profile.accountID))")
            LabeledContent("리전", value: profile.region)
            LabeledContent("환경", value: profile.environment.isEmpty ? "-" : profile.environment)
            LabeledContent("그룹", value: profile.groupName.isEmpty ? "-" : profile.groupName)
            LabeledContent("접속 방식", value: profile.connectionType.displayName)
            if profile.connectionType != .ssm {
                LabeledContent("SSH 사용자", value: profile.sshUsername)
                LabeledContent("SSH 포트", value: String(profile.sshPort))
            }
            if profile.connectionType == .bastionSSH {
                LabeledContent("Bastion", value: bastionName ?? "지정 안 됨")
            }
        } header: {
            Label("사용자 설정 (iCloud 동기화 대상)", systemImage: "person")
        }
    }

    private var localSection: some View {
        let settings = state.localSettings(for: profile.id)
        return Section {
            LabeledContent("AWS CLI 프로필", value: settings.awsCLIProfileName)
            LabeledContent("SSH 키 경로", value: settings.sshKeyPath ?? "지정 안 됨 (ssh 기본값)")
            LabeledContent("터미널", value: TerminalApp(rawValue: settings.terminalIdentifier)?.displayName ?? settings.terminalIdentifier)
            LabeledContent("연결 타임아웃", value: "\(settings.connectTimeoutSeconds)초")
        } header: {
            Label("이 Mac 전용 설정 (동기화하지 않음)", systemImage: "desktopcomputer")
        }
    }

    /// 접속 설정 화면에서 고칠 수 있는 오류
    private static func isFixedInSettings(_ error: ConnectionError) -> Bool {
        switch error {
        case .noPublicIP, .noPrivateIP, .bastionNotConfigured, .bastionNotFound, .bastionNoPublicIP,
             .invalidConfiguration, .keyFileNotFound, .unsupportedConnectionType:
            true
        default:
            false
        }
    }

    private var defaultTerminal: TerminalApp {
        TerminalApp(rawValue: state.localSettings(for: profile.id).terminalIdentifier) ?? .iTerm2
    }

    /// 예: "prod-bastion (203.0.113.5)"
    private var bastionName: String? {
        guard let id = profile.bastionProfileID, let bastion = state.profile(id: id) else { return nil }
        guard let ip = state.instances[id]?.publicIPAddress else { return bastion.displayName }
        return "\(bastion.displayName) (\(ip))"
    }

    // MARK: - Actions

    private func refreshInstance() async {
        isRefreshingInstance = true
        refreshError = nil
        defer { isRefreshingInstance = false }
        do {
            try await state.refreshInstance(id: profile.id)
        } catch {
            refreshError = error
        }
    }

    private func flashCopied() {
        copiedCommand = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copiedCommand = false
        }
    }

    /// 값 옆에 복사 버튼을 둔 행. 값이 없으면 "없음"을 표시한다.
    private func copyableRow(_ title: String, _ value: String?) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value ?? "없음")
                if let value {
                    Button {
                        ConnectionCoordinator.copy(value)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("\(title) 복사")
                    .accessibilityLabel("\(title) 복사")
                }
            }
        }
    }
}

private struct ErrorGuidance: View {
    let error: ConnectionError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(error.errorDescription ?? "접속할 수 없습니다.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
