import AppKit
import EC2DockCore
import SwiftUI

/// 서버별 접속 설정 편집. 동기화 대상(프로필)과 이 Mac 전용 설정을 구분해 보여준다.
struct ConnectionSettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @ViewState private var profile: ServerProfile
    @ViewState private var settings: LocalConnectionSettings
    @ViewState private var issues: [ValidationIssue] = []

    init(profile: ServerProfile, settings: LocalConnectionSettings) {
        _profile = ViewState(initialValue: profile)
        _settings = ViewState(initialValue: settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("서버 프로필 (iCloud 동기화 대상)") {
                    LabeledContent("인스턴스", value: "\(state.accountLabel(for: profile.accountID)) · \(profile.region) · \(profile.instanceID)")
                    TextField("표시 이름", text: $profile.displayName)
                    TextField("환경", text: $profile.environment, prompt: Text("Production / Development"))
                    TextField("그룹", text: $profile.groupName)
                    Picker("접속 방식", selection: $profile.connectionType) {
                        ForEach(ConnectionType.allCases) { Text($0.displayName).tag($0) }
                    }
                    if profile.connectionType != .ssm {
                        TextField("SSH 사용자명", text: $profile.sshUsername)
                        TextField("SSH 포트", value: $profile.sshPort, format: .number.grouping(.never))
                    }
                    if profile.connectionType == .bastionSSH {
                        let candidates = state.bastionCandidates(for: profile)
                        Picker("Bastion 서버", selection: $profile.bastionProfileID) {
                            Text("선택 안 함").tag(String?.none)
                            ForEach(candidates) { candidate in
                                Text(bastionLabel(candidate)).tag(Optional(candidate.id))
                            }
                        }
                        Text(candidates.isEmpty
                             ? "같은 계정·VPC에 공인 IP가 있는 서버가 없습니다. 목록을 새로고침한 뒤 다시 확인하세요."
                             : "같은 계정·VPC에서 공인 IP가 있는 서버만 표시합니다. Bastion의 사용자명·포트·키는 그 서버의 접속 설정을 사용합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("이 Mac 전용 설정 (동기화하지 않음)") {
                    Picker("AWS CLI 프로필", selection: $settings.awsCLIProfileName) {
                        ForEach(awsProfileOptions, id: \.self) { Text($0).tag($0) }
                    }
                    HStack {
                        TextField("SSH 키 파일 경로", text: keyPath, prompt: Text("~/.ssh/my-key.pem"))
                        Button("선택…", action: chooseKeyFile)
                    }
                    Picker("터미널", selection: $settings.terminalIdentifier) {
                        ForEach(TerminalApp.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    Stepper(value: $settings.connectTimeoutSeconds, in: 1...120) {
                        LabeledContent("연결 타임아웃", value: "\(settings.connectTimeoutSeconds)초")
                    }
                    Text("SSH 키 파일 경로만 저장하며 개인키 내용은 읽거나 저장하지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !issues.isEmpty {
                    Section {
                        ForEach(issues, id: \.message) { issue in
                            Label(issue.message, systemImage: "exclamationmark.circle")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("저장") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 600)
    }

    /// 예: "prod-bastion · 203.0.113.5"
    private func bastionLabel(_ candidate: ServerProfile) -> String {
        guard let ip = state.instances[candidate.id]?.publicIPAddress else { return candidate.displayName }
        return "\(candidate.displayName) · \(ip)"
    }

    /// 현재 값이 조회된 목록에 없더라도 선택지에 남겨 둔다.
    private var awsProfileOptions: [String] {
        Array(Set(state.availableAWSProfiles + [settings.awsCLIProfileName])).sorted()
    }

    private var keyPath: Binding<String> {
        Binding(
            get: { settings.sshKeyPath ?? "" },
            set: { settings.sshKeyPath = $0.isEmpty ? nil : $0 }
        )
    }

    /// 경로만 받아 오며 파일 내용은 읽지 않는다.
    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.message = "SSH 개인키 파일을 선택하세요. 경로만 저장하며 키 내용은 읽지 않습니다."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.sshKeyPath = (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func save() {
        issues = state.updateConnectionSettings(profile: profile, settings: settings)
        if issues.isEmpty { dismiss() }
    }
}
