import EC2DockCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: SidebarItem?
    @ViewState private var showsAddAccount = false
    @ViewState private var showsAddManualServer = false
    @ViewState private var renamingAccount: AccountSummary?
    @ViewState private var renameText = ""

    /// 표시 이름이 겹치는 계정 (계정 ID 끝자리로 구분한다)
    private var duplicatedAliases: Set<String> {
        let counts = Dictionary(state.accounts.map { ($0.alias, 1) }, uniquingKeysWith: +)
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                // macOS 27 사이드바 섹션 헤더는 .collapsible(false)여도 호버 시 접기 화살표가 나타나므로 헤더를 선택 불가 행으로 그린다.
                Text("서버")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()

                Label("전체 서버", systemImage: "server.rack")
                    .tag(SidebarItem.servers(.all))
                Label("즐겨찾기", systemImage: "star")
                    .tag(SidebarItem.servers(.favorites))
                Label("운영 (Production)", systemImage: "exclamationmark.shield")
                    .tag(SidebarItem.servers(.production))
                Label("개발 (Development)", systemImage: "hammer")
                    .tag(SidebarItem.servers(.development))
                if state.profiles.contains(where: \.isManual) {
                    Label("직접 추가한 서버", systemImage: "desktopcomputer")
                        .tag(SidebarItem.servers(.manual))
                }
            }

            Section {
                HStack {
                    Text("AWS 계정")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showsAddManualServer = true
                    } label: {
                        Image(systemName: "plus.rectangle")
                    }
                    .buttonStyle(.borderless)
                    .help("서버 직접 추가")
                    .accessibilityLabel("서버 직접 추가")

                    Button {
                        showsAddAccount = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("AWS 계정 추가")
                    .accessibilityLabel("AWS 계정 추가")
                }
                .selectionDisabled()

                ForEach(state.accounts) { account in
                    Label {
                        HStack {
                            Text(account.alias)
                            if duplicatedAliases.contains(account.alias) {
                                Text("·…\(account.accountID.suffix(4))")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(account.isPending ? "조회 전" : account.isScanned ? "\(account.serverCount)" : "조회 안 함 · \(account.serverCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: account.isPending ? "clock" : "person.crop.square")
                    }
                    .help(account.isPending
                          ? "AWS CLI 프로필 \(account.alias): 목록을 새로고침하면 서버가 표시됩니다"
                          : account.isScanned
                              ? "계정 \(account.accountID) · 프로필 \(account.awsProfile ?? account.alias)"
                              : "계정 \(account.accountID) · 이 Mac의 조회 대상 프로필과 연결되어 있지 않습니다(캐시/동기화된 서버)")
                    .foregroundStyle(account.isScanned || account.isPending ? .primary : .secondary)
                    .tag(SidebarItem.servers(.account(account.accountID)))
                    .contextMenu {
                        if !account.isPending {
                            Button("이름 변경…") {
                                renameText = account.alias
                                renamingAccount = account
                            }
                            if state.customAccountName(for: account.accountID) != nil {
                                Button("기본 이름으로 되돌리기") {
                                    state.renameAccount(account.accountID, to: "")
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $showsAddAccount) {
            AddAWSAccountView()
        }
        .sheet(isPresented: $showsAddManualServer) {
            AddManualServerView()
        }
        .alert("계정 이름 변경",
               isPresented: Binding(get: { renamingAccount != nil }, set: { if !$0 { renamingAccount = nil } }),
               presenting: renamingAccount) { account in
            TextField("이름", text: $renameText)
            Button("저장") { state.renameAccount(account.accountID, to: renameText) }
            Button("취소", role: .cancel) {}
        } message: { account in
            Text("계정 \(account.accountID)의 표시 이름입니다. 이 Mac의 사이드바에만 적용되며, 비우면 기본 이름으로 돌아갑니다.")
        }
        // 설정은 macOS 표준 설정 창(⌘,)으로 연다.
        .safeAreaInset(edge: .bottom) {
            SettingsLink {
                Label("설정", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .help("설정 (⌘,)")
        }
    }
}
