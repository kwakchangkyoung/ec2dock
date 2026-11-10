import AppKit
import EC2DockCore
import SwiftUI

/// 수동으로 서버(온프레미스, 타 클라우드 등)를 추가하는 시트.
struct AddManualServerView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @ViewState private var displayName = ""
    @ViewState private var host = ""
    @ViewState private var sshUsername = "ec2-user"
    @ViewState private var sshPort = 22
    @ViewState private var sshKeyPath = ""
    @ViewState private var environment = ""
    @ViewState private var groupName = ""
    @ViewState private var connectionType: ConnectionType = .directSSH
    @ViewState private var bastionProfileID: String?
    @ViewState private var issues: [ValidationIssue] = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("서버 프로필 (iCloud 동기화 대상)") {
                    TextField("표시 이름", text: $displayName, prompt: Text("예: my-server-01"))
                    TextField("호스트", text: $host, prompt: Text("예: 192.168.1.100 또는 server.example.com"))
                    TextField("SSH 사용자명", text: $sshUsername)
                    TextField("SSH 포트", value: $sshPort, format: .number.grouping(.never))
                    TextField("환경", text: $environment, prompt: Text("Production / Development"))
                    environmentHint
                    TextField("그룹", text: $groupName, prompt: Text("예: on-prem, database"))
                    Picker("접속 방식", selection: $connectionType) {
                        Text(ConnectionType.directSSH.displayName).tag(ConnectionType.directSSH)
                        Text(ConnectionType.bastionSSH.displayName).tag(ConnectionType.bastionSSH)
                    }
                    if connectionType == .bastionSSH {
                        let tempProfile = ServerProfile.manual(
                            displayName: displayName,
                            host: host,
                            environment: environment,
                            groupName: groupName,
                            connectionType: connectionType,
                            sshUsername: sshUsername,
                            sshPort: sshPort,
                            bastionProfileID: bastionProfileID
                        )
                        let candidates = state.bastionCandidates(for: tempProfile)
                        Picker("Bastion 서버", selection: $bastionProfileID) {
                            Text("선택 안 함").tag(String?.none)
                            ForEach(candidates) { candidate in
                                Text(bastionLabel(candidate)).tag(Optional(candidate.id))
                            }
                        }
                        Text(candidates.isEmpty
                             ? "Bastion으로 사용할 수 있는 직접 추가한 서버가 없습니다."
                             : "Bastion의 사용자명·포트·키는 그 서버의 접속 설정을 사용합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("이 Mac 전용 설정 (동기화하지 않음)") {
                    HStack {
                        TextField("SSH 키 파일 경로 (선택)", text: $sshKeyPath, prompt: Text("~/.ssh/id_ed25519"))
                        Button("선택…", action: chooseKeyFile)
                    }
                    Text("SSH 키 파일 경로만 이 Mac에 저장하며 개인키 내용은 읽거나 동기화하지 않습니다.")
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
                Button("추가") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 600)
    }

    private var environmentHint: some View {
        let isProd = ServerProfile.manual(displayName: displayName, host: host, environment: environment).isProduction
        let text = if !isProd {
            "운영 서버로 인식되지 않습니다. 운영 서버라면 production, prod, 운영 등으로 입력하세요."
        } else if state.preferences.confirmProductionConnections {
            "운영 서버로 취급합니다. 접속·파일 열기·명령 복사 전에 한 번 더 확인합니다."
        } else {
            "운영 서버로 취급합니다. 설정에서 \"운영 서버 접속 전 확인\"이 꺼져 있어 확인 창은 뜨지 않습니다."
        }
        return Label(text, systemImage: isProd ? "exclamationmark.shield" : "info.circle")
            .font(.caption)
            .foregroundStyle(isProd ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
    }

    private func bastionLabel(_ candidate: ServerProfile) -> String {
        if candidate.isManual {
            return "\(candidate.displayName) · \(candidate.host ?? "-")"
        }
        guard let ip = state.instances[candidate.id]?.publicIPAddress else { return candidate.displayName }
        return "\(candidate.displayName) · \(ip)"
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.message = "SSH 개인키 파일을 선택하세요. 경로만 저장하며 키 내용은 읽지 않습니다."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sshKeyPath = (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func save() {
        let profile = ServerProfile.manual(
            displayName: displayName,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            environment: environment,
            groupName: groupName,
            connectionType: connectionType,
            sshUsername: sshUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            sshPort: sshPort,
            bastionProfileID: connectionType == .bastionSSH ? bastionProfileID : nil
        )
        let trimmedKey = sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var settings = state.localSettings(for: profile.id)
        settings.sshKeyPath = trimmedKey.isEmpty ? nil : trimmedKey
        issues = state.addManualServer(profile: profile, settings: settings)
        if issues.isEmpty {
            dismiss()
        }
    }
}
