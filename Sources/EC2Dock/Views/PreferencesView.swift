import EC2DockCore
import SwiftUI

struct PreferencesView: View {
    @Environment(AppState.self) private var state
    @ViewState private var newRegion = ""
    @ViewState private var regionError: String?
    @ViewState private var confirmsEnablingSync = false
    @ViewState private var showsConflicts = false
    @ViewState private var showsAddAccount = false

    private static let refreshIntervals = [0, 5, 15, 30, 60]

    var body: some View {
        @Bindable var state = state

        Form {
            Section("AWS") {
                Picker("기본 AWS CLI 프로필", selection: $state.preferences.defaultAWSProfile) {
                    ForEach(awsProfileOptions, id: \.self) { Text($0).tag($0) }
                }
                Picker("기본 리전", selection: defaultRegionBinding) {
                    ForEach(defaultRegionOptions, id: \.self) { Text(AWSRegions.displayName(for: $0)).tag($0) }
                }
                .help("기본 리전은 조회 리전에 자동으로 추가되며 삭제할 수 없습니다.")
                Picker("자동 새로고침", selection: $state.preferences.autoRefreshIntervalMinutes) {
                    ForEach(Self.refreshIntervals, id: \.self) { minutes in
                        Text(minutes == 0 ? "사용 안 함" : "\(minutes)분").tag(minutes)
                    }
                }
            }

            Section {
                if awsProfileOptions.isEmpty {
                    Text("AWS CLI 프로필이 없습니다. 아래 \"AWS 계정 추가…\"로 로그인해 프로필을 만드세요.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(awsProfileOptions, id: \.self) { profile in
                        Toggle(profile, isOn: enabledBinding(for: profile))
                    }
                }
                HStack {
                    Button("AWS 계정 추가…") { showsAddAccount = true }
                    Button("프로필 목록 다시 읽기") {
                        Task { await state.reloadAWSProfiles() }
                    }
                }
            } header: {
                Text("조회할 AWS CLI 프로필")
            } footer: {
                Text("선택하지 않으면 기본 프로필만 조회합니다. 읽기 전용 호출(sts get-caller-identity, ec2 describe-instances)만 사용하며 자격 증명은 AWS CLI 설정을 그대로 사용합니다.")
            }

            Section {
                ForEach(state.preferences.regions, id: \.self) { region in
                    HStack {
                        Text(AWSRegions.displayName(for: region))
                        Spacer()
                        Button(role: .destructive) {
                            removeRegion(region)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(region == state.preferences.defaultRegion)
                        .help(region == state.preferences.defaultRegion ? "기본 리전은 삭제할 수 없습니다" : "리전 삭제")
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
                Text("새로고침 시 여기 있는 모든 리전을 조회합니다. 서버가 있는 리전을 모두 추가하세요.")
            }

            Section("접속") {
                Picker("기본 터미널", selection: $state.preferences.defaultTerminal) {
                    ForEach(TerminalApp.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Toggle("Production 서버 접속 전 확인", isOn: $state.preferences.confirmProductionConnections)
            }

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
            } header: {
                Text("동기화")
            } footer: {
                Text("동기화: 서버 별칭, 계정 ID, 리전, 인스턴스 ID, 그룹, 환경, 즐겨찾기, 접속 방식, SSH 사용자명·포트, Bastion 참조\n동기화하지 않음: SSH 키 경로와 개인키, AWS 자격 증명과 프로필 매핑, IP·상태 캐시, 앱 설정")
            }

            Section("로그") {
                Picker("로그 수준", selection: $state.preferences.logLevel) {
                    ForEach(LogLevel.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("로그에는 자격 증명, 비밀 값, 전체 접속 명령을 기록하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
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
        .sheet(isPresented: $showsConflicts) {
            SyncConflictView()
        }
        .sheet(isPresented: $showsAddAccount) {
            AddAWSAccountView()
        }
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

    private var awsProfileOptions: [String] {
        Array(Set(state.availableAWSProfiles + [state.preferences.defaultAWSProfile])).sorted()
    }

    /// 조회 리전에 없는 리전도 고를 수 있다. 목록에 없는 기본 리전 값도 선택지에 남긴다.
    private var defaultRegionOptions: [String] {
        let known = AWSRegions.known.map(\.code)
        let extra = (state.preferences.regions + [state.preferences.defaultRegion]).filter { !known.contains($0) }
        return known + Array(Set(extra)).sorted()
    }

    /// 기본 리전을 바꾸면 조회 리전에도 추가한다.
    private var defaultRegionBinding: Binding<String> {
        Binding(
            get: { state.preferences.defaultRegion },
            set: { region in
                if !state.preferences.regions.contains(region) {
                    state.preferences.regions.append(region)
                }
                state.preferences.defaultRegion = region
            }
        )
    }

    private func enabledBinding(for profile: String) -> Binding<Bool> {
        Binding(
            get: { state.preferences.enabledAWSProfiles.contains(profile) },
            set: { isOn in
                state.preferences.enabledAWSProfiles.removeAll { $0 == profile }
                if isOn { state.preferences.enabledAWSProfiles.append(profile) }
                state.preferences.enabledAWSProfiles.sort()
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

    private func removeRegion(_ region: String) {
        state.preferences.regions.removeAll { $0 == region }
    }
}
