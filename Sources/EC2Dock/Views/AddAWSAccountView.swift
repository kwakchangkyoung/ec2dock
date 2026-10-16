import EC2DockCore
import SwiftUI

/// 앱 안에서 AWS 계정(AWS CLI 프로필)을 추가한다.
/// 이름과 방식 입력 → 시트 안 내장 터미널에서 로그인 → 조회 대상에 추가하고 새로고침.
/// 앱은 자격 증명을 받지 않으며, 로그인과 토큰 저장은 AWS CLI가 직접 처리한다.
struct AddAWSAccountView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case form
        case login(TerminalSessionController)
        case finishing
        case done
    }

    @ViewState private var step: Step = .form
    @ViewState private var profileName = ""
    @ViewState private var method: AWSAccountSetupMethod = .consoleLogin
    @ViewState private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .form:
                form
            case .login(let controller):
                loginView(controller)
            case .finishing:
                ProgressView("계정을 조회 대상에 추가하고 서버 목록을 새로고침하는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .done:
                doneView
            }
        }
        .frame(width: 720, height: 500)
        .onDisappear { activeController?.terminate() }
    }

    // MARK: - 1단계: 입력

    private var form: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("프로필 이름", text: $profileName, prompt: Text("예: work-prod"))
                    if profileExists {
                        Text("이미 있는 프로필입니다. 로그인이 유효하면 바로, 만료됐으면 다시 로그인한 뒤 조회 대상에 추가합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("로그인 방식", selection: $method) {
                        ForEach(AWSAccountSetupMethod.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                } footer: {
                    Text(methodHelp)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("로그인 시작") { Task { await start() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!InputValidator.isValidAWSProfileName(trimmedName))
            }
            .padding()
        }
    }

    private var methodHelp: String {
        switch method {
        case .consoleLogin:
            "브라우저에서 AWS 콘솔에 로그인한 계정으로 임시 자격 증명을 받습니다. 처음이면 터미널에서 기본 리전을 묻습니다. AWS CLI 2.32.0 이상이 필요하며, IAM 사용자는 SignInLocalDevelopmentAccess 정책이 있어야 합니다."
        case .identityCenter:
            "회사에서 IAM Identity Center(SSO)를 쓰는 경우입니다. 터미널에서 SSO 시작 URL, 리전, 계정과 역할을 차례로 고릅니다."
        }
    }

    // MARK: - 2단계: 로그인

    private func loginView(_ controller: TerminalSessionController) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label("AWS 계정 추가 · \(trimmedName)", systemImage: "person.badge.key")
                    .font(.headline)
                Spacer()
                Text("터미널의 안내에 따라 로그인을 마치세요")
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            TerminalHostView(terminalView: controller.terminalView)
                .padding(8)
                .background(Color(nsColor: TerminalSessionController.background))
            Divider()
            HStack {
                if case .exited(let code) = controller.status, code != 0 {
                    Label("로그인이 완료되지 않았습니다" + (code.map { " (종료 코드 \($0))" } ?? ""), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("다시 시도") { Task { await start() } }
                } else {
                    Spacer()
                }
                Button("취소") {
                    controller.terminate()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
    }

    // MARK: - 3단계: 결과

    private var doneView: some View {
        VStack(spacing: 14) {
            switch state.refreshStatus {
            case .failed(let failures):
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text("'\(trimmedName)' 프로필을 추가했지만 일부 조회에 실패했습니다.").font(.headline)
                ForEach(failures) { failure in
                    Text("\(failure.source): \(failure.message)").font(.callout).foregroundStyle(.secondary)
                }
            default:
                Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.green)
                Text("'\(trimmedName)' 계정을 추가했습니다.").font(.headline)
                Text("사이드바의 AWS Accounts에서 계정별 서버를 볼 수 있습니다. 서버가 보이지 않으면 Settings의 조회 리전을 확인하세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("완료") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private var trimmedName: String {
        profileName.trimmingCharacters(in: .whitespaces)
    }

    private var profileExists: Bool {
        state.availableAWSProfiles.contains(trimmedName)
    }

    private var activeController: TerminalSessionController? {
        if case .login(let controller) = step { return controller }
        return nil
    }

    private func start() async {
        errorMessage = nil
        activeController?.terminate()
        let profile = trimmedName
        // 이미 유효한 자격 증명이 있으면 "확인 성공"을 로그인 완료로 볼 수 없으므로 종료 코드만 기준으로 삼는다.
        let wasLoggedIn = await state.isLoggedIn(awsProfile: profile)
        // 이미 로그인된 기존 프로필이면 로그인 없이 바로 조회 대상에 추가한다.
        if profileExists && wasLoggedIn {
            await complete(profile: profile)
            return
        }
        do {
            // 이미 있는 프로필은 다시 로그인만 한다.
            let session = profileExists
                ? try await state.loginSession(for: profile)
                : try await state.addAccountSession(profile: profile, method: method)
            let controller = TerminalSessionController(session: session)
            controller.onExit = { _, exitCode in
                guard exitCode == 0 else { return }
                Task { await finish(profile: profile, controller: controller) }
            }
            step = .login(controller)
            if !wasLoggedIn { watchLogin(profile: profile, controller: controller) }
        } catch {
            step = .form
            errorMessage = TerminalErrorText.describe(error)
        }
    }

    /// 로그인 후에도 aws 명령이 바로 끝나지 않을 수 있어(브라우저 콜백 연결 등) 2초마다 로그인 여부를 확인한다.
    private func watchLogin(profile: String, controller: TerminalSessionController) {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard isCurrent(controller), controller.isRunning else { return }
                if await state.isLoggedIn(awsProfile: profile) {
                    await finish(profile: profile, controller: controller)
                    return
                }
            }
        }
    }

    /// 한 번만 실행된다. 남은 로그인 명령을 정리하고, 조회 대상에 추가·새로고침한 뒤
    /// 문제가 없으면 시트를 자동으로 닫는다.
    private func finish(profile: String, controller: TerminalSessionController) async {
        guard isCurrent(controller) else { return }
        controller.terminate()
        await complete(profile: profile)
    }

    private func complete(profile: String) async {
        step = .finishing
        await state.completeAccountAddition(profile: profile)
        if case .failed = state.refreshStatus {
            step = .done
        } else {
            dismiss()
        }
    }

    private func isCurrent(_ controller: TerminalSessionController) -> Bool {
        if case .login(let current) = step { return current === controller }
        return false
    }
}
