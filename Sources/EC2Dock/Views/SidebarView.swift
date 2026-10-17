import EC2DockCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("서버") {
                Label("전체 서버", systemImage: "server.rack")
                    .tag(SidebarItem.servers(.all))
                Label("즐겨찾기", systemImage: "star")
                    .tag(SidebarItem.servers(.favorites))
                Label("운영 (Production)", systemImage: "exclamationmark.shield")
                    .tag(SidebarItem.servers(.production))
                Label("개발 (Development)", systemImage: "hammer")
                    .tag(SidebarItem.servers(.development))
            }

            Section("AWS 계정") {
                ForEach(state.accounts) { account in
                    Label {
                        HStack {
                            Text(account.alias)
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
                              ? "계정 \(account.accountID) · 프로필 \(account.alias)"
                              : "계정 \(account.accountID) · 이 Mac의 조회 대상 프로필과 연결되어 있지 않습니다(캐시/동기화된 서버)")
                    .foregroundStyle(account.isScanned || account.isPending ? .primary : .secondary)
                    .tag(SidebarItem.servers(.account(account.accountID)))
                }
            }
        }
        .listStyle(.sidebar)
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
