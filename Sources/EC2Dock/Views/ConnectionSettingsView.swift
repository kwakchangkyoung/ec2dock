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
                    if profile.isManual {
                        TextField("호스트", text: Binding(
                            get: { profile.host ?? "" },
                            set: { profile.host = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        ), prompt: Text("예: 192.168.1.100 또는 server.example.com"))
                    } else {
                        LabeledContent("인스턴스", value: "\(state.accountLabel(for: profile.accountID)) · \(profile.region) · \(profile.instanceID)")
                    }
                    TextField("표시 이름", text: $profile.displayName)
                    TextField("환경", text: $profile.environment, prompt: Text("Production / Development"))
                    environmentHint
                    TextField("그룹", text: $profile.groupName)
                    Picker("접속 방식", selection: $profile.connectionType) {
                        if profile.isManual {
                            Text(ConnectionType.directSSH.displayName).tag(ConnectionType.directSSH)
                            Text(ConnectionType.bastionSSH.displayName).tag(ConnectionType.bastionSSH)
                        } else {
                            // SSM은 아직 접속을 지원하지 않는다.
                            ForEach(ConnectionType.allCases) { Text($0 == .ssm ? "SSM (준비 중)" : $0.displayName).tag($0) }
                        }
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
                             ? (profile.isManual ? "Bastion으로 사용할 수 있는 직접 추가한 서버가 없습니다." : "같은 계정·VPC에 공인 IP가 있는 서버나 직접 추가한 서버가 없습니다.")
                             : "Bastion의 사용자명·포트·키는 그 서버의 접속 설정을 사용합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("이 Mac 전용 설정 (동기화하지 않음)") {
                    if !profile.isManual {
                        Picker("AWS CLI 프로필", selection: $settings.awsCLIProfileName) {
                            ForEach(awsProfileOptions, id: \.self) { Text($0).tag($0) }
                        }
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
    /// 입력한 환경 값이 운영으로 판정되는지 바로 보여준다 (운영이면 접속 전에 확인 창이 뜬다).
    private var environmentHint: some View {
        let text = if !profile.isProduction {
            "운영 서버로 인식되지 않습니다. 운영 서버라면 production, prod, 운영 등으로 입력하세요."
        } else if state.preferences.confirmProductionConnections {
            "운영 서버로 취급합니다. 접속·파일 열기·명령 복사 전에 한 번 더 확인합니다."
        } else {
            "운영 서버로 취급합니다. 설정에서 \"운영 서버 접속 전 확인\"이 꺼져 있어 확인 창은 뜨지 않습니다."
        }
        return Label(text, systemImage: profile.isProduction ? "exclamationmark.shield" : "info.circle")
            .font(.caption)
            .foregroundStyle(profile.isProduction ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
    }

    private func bastionLabel(_ candidate: ServerProfile) -> String {
        if candidate.isManual {
            return "\(candidate.displayName) · \(candidate.host ?? "-")"
        }
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
