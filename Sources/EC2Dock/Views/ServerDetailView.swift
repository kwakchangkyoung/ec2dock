import AppKit
import EC2DockCore
import SwiftUI

struct ServerDetailView: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    let item: ServerListItem

    @ViewState private var isConnecting = false
    @ViewState private var connectionError: ConnectionError?
    @ViewState private var resultMessage: String?
    @ViewState private var pendingProductionTarget: ConnectionTarget?
    /// 이번 접속에서 고른 열기 방식 (nil이면 서버 설정의 터미널)
    @ViewState private var chosenTerminal: TerminalApp?
    /// 터미널 실행이 실패했을 때 대체 실행(FR-015)에 쓰는 마지막 시도
    @ViewState private var failedAttempt: (target: ConnectionTarget, confirmed: Bool, terminal: TerminalApp)?
    @ViewState private var copiedCommand = false
    @ViewState private var isEditingSettings = false
    @ViewState private var isRefreshingInstance = false
    @ViewState private var refreshError: ConnectionError?

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
                    isEditingSettings = true
                } label: {
                    Label("접속 설정 편집", systemImage: "slider.horizontal.3")
                }
                .help("접속 설정 편집 (접속 방식, Bastion, SSH 사용자·포트·키, 터미널)")
            }
        }
        .sheet(isPresented: $isEditingSettings) {
            ConnectionSettingsView(profile: profile, settings: state.localSettings(for: profile.id))
        }
        .productionConfirmation(target: $pendingProductionTarget, accountLabel: state.accountLabel(for:)) { target in
            Task { await perform(target, productionConfirmed: true, terminal: chosenTerminal) }
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
            HStack {
                // 기본 클릭은 서버 설정의 터미널로 열고, 화살표 메뉴로 다른 방식을 고를 수 있다.
                Menu {
                    ForEach(TerminalApp.allCases) { app in
                        Button("\(app.displayName)로 열기") {
                            Task { await connect(using: app) }
                        }
                    }
                } label: {
                    Label("Connect", systemImage: "terminal")
                        .frame(minWidth: 100)
                } primaryAction: {
                    Task { await connect(using: nil) }
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fixedSize()
                .disabled(blockingReason != nil || isConnecting)
                .help("클릭: \(defaultTerminal.displayName)로 열기 · 화살표: 열기 방식 선택")

                if isConnecting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("\(profile.connectionType.displayName) · \(defaultTerminal.displayName)")
                    .foregroundStyle(.secondary)
                Button("접속 설정…") { isEditingSettings = true }
                    .help("접속 방식, Bastion, SSH 사용자·포트·키, 터미널을 설정합니다")
            }

            let openSessions = terminals.sessions(for: profile.id)
            if !openSessions.isEmpty {
                HStack {
                    Label("이 서버에 열린 내장 터미널 \(openSessions.count)개", systemImage: "terminal")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("터미널로 이동") {
                        terminals.activeSessionID = openSessions.last?.id
                    }
                }
            }

            if let error = connectionError ?? blockingReason {
                ErrorGuidance(error: error)
                if Self.isFixedInSettings(error) {
                    Button("접속 설정 열기") { isEditingSettings = true }
                }
                if let failedAttempt {
                    fallbackActions(for: failedAttempt)
                }
            } else if let resultMessage {
                Label(resultMessage, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        } footer: {
            Text(cacheFooter)
        }
    }

    private func fallbackActions(for attempt: (target: ConnectionTarget, confirmed: Bool, terminal: TerminalApp)) -> some View {
        HStack {
            if attempt.terminal != .embedded {
                Button("내장 터미널로 열기") {
                    Task { await perform(attempt.target, productionConfirmed: attempt.confirmed, terminal: .embedded) }
                }
            }
            if attempt.terminal != .terminal {
                Button("Terminal로 열기") {
                    Task { await perform(attempt.target, productionConfirmed: attempt.confirmed, terminal: .terminal) }
                }
            }
            Button(copiedCommand ? "복사됨" : "명령 복사") {
                copyCommand(for: attempt.target)
            }
            .help("SSH 명령을 클립보드에 복사합니다. 터미널에 붙여 넣어 직접 실행하세요.")
        }
        .disabled(isConnecting)
    }

    private var awsSection: some View {
        Section {
            LabeledContent("인스턴스 ID", value: profile.instanceID)
            if let instance = item.instance {
                LabeledContent("상태", value: instance.state)
                LabeledContent("공인 IP", value: instance.publicIPAddress ?? "없음")
                LabeledContent("사설 IP", value: instance.privateIPAddress ?? "없음")
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
        return "Connect는 \(fetched.formatted(.relative(presentation: .named)))에 조회한 IP로 바로 접속합니다. " + hostKeyNote
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

    private func connect(using terminal: TerminalApp?) async {
        isConnecting = true
        connectionError = nil
        resultMessage = nil
        failedAttempt = nil
        copiedCommand = false
        chosenTerminal = terminal
        defer { isConnecting = false }

        do {
            let target = try state.prepareConnection(for: profile.id)
            if state.requiresProductionConfirmation(for: target.profile) {
                pendingProductionTarget = target
            } else {
                await perform(target, productionConfirmed: false, terminal: terminal)
            }
        } catch {
            connectionError = error
        }
    }

    private func refreshInstance() async {
        isRefreshingInstance = true
        refreshError = nil
        connectionError = nil
        defer { isRefreshingInstance = false }
        do {
            try await state.refreshInstance(id: profile.id)
        } catch {
            refreshError = error
        }
    }

    private func perform(_ target: ConnectionTarget, productionConfirmed: Bool, terminal: TerminalApp? = nil) async {
        isConnecting = true
        connectionError = nil
        resultMessage = nil
        defer { isConnecting = false }

        let app = terminal ?? TerminalApp(rawValue: target.settings.terminalIdentifier) ?? .iTerm2
        do {
            switch try await state.connect(target, productionConfirmed: productionConfirmed, terminal: app) {
            case .external(let message):
                resultMessage = message
            case .embedded(let session):
                // 상세 영역에 새 터미널 탭을 열고 바로 보여준다.
                terminals.open(session)
            }
            failedAttempt = nil
        } catch let error as ConnectionError {
            connectionError = error
            switch error {
            case .terminalUnavailable, .automationPermissionDenied, .launchFailed:
                failedAttempt = (target, productionConfirmed, app)
            default:
                failedAttempt = nil
            }
        } catch {
            connectionError = .launchFailed(error.localizedDescription)
            failedAttempt = (target, productionConfirmed, app)
        }
    }

    private func copyCommand(for target: ConnectionTarget) {
        do {
            let command = try state.commandLine(for: target)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copiedCommand = true
        } catch let error as ConnectionError {
            connectionError = error
        } catch {
            connectionError = .launchFailed(error.localizedDescription)
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
