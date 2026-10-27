import EC2DockCore
import SwiftUI

/// 설정 창 (⌘,): 일반 / AWS / 터미널 / 동기화
struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("일반", systemImage: "gearshape") }
            AWSSettingsTab()
                .tabItem { Label("AWS", systemImage: "cloud") }
            TerminalSettingsTab()
                .tabItem { Label("터미널", systemImage: "terminal") }
            SyncSettingsTab()
                .tabItem { Label("동기화", systemImage: "icloud") }
        }
    }
}

// MARK: - 일반

private struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var state
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        @Bindable var state = state
        @Bindable var updater = updater
        Form {
            Section {
                LabeledContent("현재 버전", value: updater.currentVersion)
                if updater.isAvailable {
                    Toggle("새 버전 자동으로 확인", isOn: $updater.automaticallyChecksForUpdates)
                    Toggle("새 버전을 내려받아 두고 종료할 때 설치", isOn: $updater.automaticallyDownloadsUpdates)
                        .disabled(!updater.automaticallyChecksForUpdates)
                    Button("지금 확인") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } header: {
                Text("업데이트")
            } footer: {
                Text(updater.isAvailable
                     ? "GitHub 릴리스에서 하루에 한 번 확인합니다. 업데이트 파일은 서명을 확인한 뒤에만 설치합니다."
                     : "앱 번들(EC2Dock.app)로 실행할 때만 업데이트를 확인합니다.")
            }
            Section("접속") {
                Toggle("운영(Production) 서버 접속 전 확인", isOn: $state.preferences.confirmProductionConnections)
                Text("서버 이름, 계정, 리전, 접속 주소를 보여주고 한 번 더 확인합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("서버 목록") {
                Picker("정렬", selection: $state.preferences.listSort) {
                    ForEach(ServerSortOrder.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("묶기", selection: $state.preferences.listGrouping) {
                    ForEach(ServerGrouping.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("보기", selection: $state.preferences.listDensity) {
                    ForEach(ServerListDensity.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if !state.deletedProfiles.isEmpty {
                Section {
                    ForEach(state.deletedProfiles.sorted { $0.deletedAt > $1.deletedAt }) { tombstone in
                        LabeledContent {
                            Button("복원") { state.restoreDeletedProfile(id: tombstone.id) }
                        } label: {
                            Text(tombstone.profile.displayName)
                            Text("\(tombstone.profile.instanceID) · \(tombstone.deletedAt.formatted(date: .abbreviated, time: .shortened)) 삭제")
                        }
                    }
                } header: {
                    Text("삭제한 서버")
                } footer: {
                    Text("삭제한 서버는 새로고침해도 다시 추가되지 않습니다. 복원하면 목록에 돌아오고, 새로고침하면 IP와 상태가 다시 채워집니다.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AWS

private struct AWSSettingsTab: View {
    @Environment(AppState.self) private var state
    @ViewState private var newRegion = ""
    @ViewState private var regionError: String?
    @ViewState private var showsAddAccount = false

    private static let refreshIntervals = [0, 5, 15, 30, 60]

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                if state.isAWSCLIMissing {
                    Label("AWS CLI를 찾을 수 없습니다. 터미널에서 brew install awscli 로 설치하세요.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if state.availableAWSProfiles.isEmpty {
                    Text("AWS CLI 프로필이 없습니다. 아래 \"AWS 계정 추가…\"로 로그인해 프로필을 만드세요.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.availableAWSProfiles, id: \.self) { profile in
                        Toggle(profile, isOn: scanBinding(for: profile))
                    }
                }
                HStack {
                    Button("AWS 계정 추가…") { showsAddAccount = true }
                        .disabled(state.isAWSCLIMissing)
                    Button("프로필 목록 다시 읽기") {
                        Task { await state.reloadAWSProfiles() }
                    }
                }
            } header: {
                Text("조회할 계정 (AWS CLI 프로필)")
            } footer: {
                Text("켜진 프로필만 새로고침 때 조회합니다. 읽기 전용 호출(sts get-caller-identity, ec2 describe-instances)만 사용하며 자격 증명은 AWS CLI 설정을 그대로 씁니다.")
            }

            Section {
                ForEach(state.preferences.regions, id: \.self) { region in
                    HStack {
                        Text(AWSRegions.displayName(for: region))
                        Spacer()
                        Button(role: .destructive) {
                            state.preferences.regions.removeAll { $0 == region }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(state.preferences.regions.count <= 1)
                        .help(state.preferences.regions.count <= 1 ? "조회 리전은 하나 이상 있어야 합니다" : "리전 삭제")
                        .accessibilityLabel("\(region) 삭제")
                    }
                }
                Menu("리전 추가") {
                    ForEach(AWSRegions.known.filter { !state.preferences.regions.contains($0.code) }, id: \.code) { region in
                        Button(AWSRegions.displayName(for: region.code)) {
                            state.preferences.regions.append(region.code)
                        }
                    }
                }
                HStack {
                    TextField("목록에 없는 리전 코드", text: $newRegion, prompt: Text("예: us-west-2"))
                        .onSubmit(addRegion)
                    Button("추가", action: addRegion)
                        .disabled(newRegion.isEmpty)
                }
                if let regionError {
                    Text(regionError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("조회 리전")
            } footer: {
                Text("새로고침 때 켜진 계정마다 여기 있는 모든 리전을 조회합니다. 서버가 있는 리전을 모두 추가하세요.")
            }

            Section("새로고침") {
                Picker("자동 새로고침", selection: $state.preferences.autoRefreshIntervalMinutes) {
                    ForEach(Self.refreshIntervals, id: \.self) { minutes in
                        Text(minutes == 0 ? "사용 안 함 (직접 새로고침)" : "\(minutes)분마다").tag(minutes)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsAddAccount) { AddAWSAccountView() }
    }

    /// "기본 프로필"과 "조회할 프로필"을 하나로 다룬다: 지금 조회 대상인 프로필이 켜져 보인다.
    private func scanBinding(for profile: String) -> Binding<Bool> {
        Binding(
            get: { state.preferences.profilesToScan.contains(profile) },
            set: { isOn in
                var updated = state.preferences.profilesToScan.filter(state.availableAWSProfiles.contains)
                updated.removeAll { $0 == profile }
                if isOn { updated.append(profile) }
                updated.sort()
                state.preferences.enabledAWSProfiles = updated
                // 계정 대응을 모르는 서버의 기본 조회 프로필도 켜진 프로필 중 하나로 맞춘다.
                if let first = updated.first, !updated.contains(state.preferences.defaultAWSProfile) {
                    state.preferences.defaultAWSProfile = first
                }
            }
        )
    }

    private func addRegion() {
        let region = newRegion.trimmingCharacters(in: .whitespaces).lowercased()
        guard InputValidator.isValidRegion(region) else {
            regionError = "리전 형식이 올바르지 않습니다. 예: ap-northeast-2"
            return
        }
        if !state.preferences.regions.contains(region) {
            state.preferences.regions.append(region)
        }
        newRegion = ""
        regionError = nil
    }
}

// MARK: - 터미널

private struct TerminalSettingsTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let range = AppPreferences.terminalFontSizeRange
        Form {
            Section("열기") {
                Picker("기본 터미널", selection: $state.preferences.defaultTerminal) {
                    ForEach(TerminalApp.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Toggle("iTerm2는 열린 창의 새 탭으로 열기", isOn: $state.preferences.iTermOpensNewTab)
                Toggle("내장 터미널을 볼 때 목록을 접어 넓게 보기", isOn: $state.preferences.autoFocusTerminal)
                Text("넓게 보기는 언제든 ⇧⌘F로 켜고 끌 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("내장 터미널 모양") {
                Stepper(value: $state.preferences.terminalFontSize, in: range, step: 1) {
                    LabeledContent("글자 크기", value: "\(Int(state.preferences.terminalFontSize))pt")
                }
                Picker("테마", selection: $state.preferences.terminalTheme) {
                    ForEach(TerminalTheme.allCases) { Text($0.displayName).tag($0) }
                }
                TerminalPreview(fontSize: state.preferences.terminalFontSize, theme: state.preferences.terminalTheme)
                Text("⌘+ / ⌘− 로 크기를 바로 바꾸고, ⌥⌘0 으로 기본 크기로 돌아갑니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TerminalPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let fontSize: Double
    let theme: TerminalTheme

    var body: some View {
        let colors = TerminalAppearance(fontSize: fontSize, theme: theme, systemIsDark: colorScheme == .dark).colors
        Text("ec2-user@ip-10-0-1-10:~$ uptime\n 10:24  up 12 days,  load average: 0.12")
            .font(.system(size: fontSize, design: .monospaced))
            .foregroundStyle(Color(nsColor: colors.foreground))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: colors.background), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
    }
}

// MARK: - 동기화

private struct SyncSettingsTab: View {
    @Environment(AppState.self) private var state
    @ViewState private var confirmsEnablingSync = false
    @ViewState private var showsConflicts = false

    var body: some View {
        Form {
            Section {
                Toggle("iCloud Drive로 서버 프로필 동기화", isOn: syncEnabledBinding)
                LabeledContent("상태", value: state.syncStatus.summary)
                switch state.syncAvailability {
                case .available(let location):
                    LabeledContent("저장 위치", value: location)
                case .unavailable(let reason):
                    LabeledContent("저장 위치", value: reason)
                case nil:
                    EmptyView()
                }
                HStack {
                    Button("지금 동기화") { Task { await state.syncNow() } }
                        .disabled(!state.preferences.iCloudSyncEnabled || state.syncStatus == .syncing)
                    if !state.syncConflicts.isEmpty {
                        Button("충돌 \(state.syncConflicts.count)건 해결…") { showsConflicts = true }
                    }
                }
            } footer: {
                Text("동기화: 서버 별칭, 계정 ID, 리전, 인스턴스 ID, 그룹, 환경, 즐겨찾기, 접속 방식, SSH 사용자명·포트, Bastion 참조\n동기화하지 않음: SSH 키 경로와 개인키, AWS 자격 증명과 프로필 매핑, IP·상태 캐시, 앱 설정")
            }
        }
        .formStyle(.grouped)
        .task { await state.refreshSyncAvailability() }
        .alert("iCloud 동기화를 켤까요?", isPresented: $confirmsEnablingSync) {
            Button("켜기") {
                state.preferences.iCloudSyncEnabled = true
                Task { await state.syncNow() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("서버 이름, AWS 계정 ID, 인스턴스 ID가 iCloud Drive에 저장됩니다. 회사 정책상 운영 정보를 개인 iCloud에 저장해도 되는지 먼저 확인하세요. SSH 키와 AWS 자격 증명은 저장하지 않습니다.")
        }
        .sheet(isPresented: $showsConflicts) { SyncConflictView() }
    }

    /// 켤 때는 확인을 거치고, 끌 때는 바로 끈다 (이 Mac의 데이터는 그대로 남는다).
    private var syncEnabledBinding: Binding<Bool> {
        Binding(
            get: { state.preferences.iCloudSyncEnabled },
            set: { isOn in
                if isOn {
                    confirmsEnablingSync = true
                } else {
                    state.preferences.iCloudSyncEnabled = false
                    Task { await state.syncNow() }
                }
            }
        )
    }
}
