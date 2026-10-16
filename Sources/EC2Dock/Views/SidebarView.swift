import EC2DockCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Servers") {
                Label("All Servers", systemImage: "server.rack")
                    .tag(SidebarItem.servers(.all))
                Label("Favorites", systemImage: "star")
                    .tag(SidebarItem.servers(.favorites))
                Label("Production", systemImage: "exclamationmark.shield")
                    .tag(SidebarItem.servers(.production))
                Label("Development", systemImage: "hammer")
                    .tag(SidebarItem.servers(.development))
            }

            Section("AWS Accounts") {
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

            Section {
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
    }
}
