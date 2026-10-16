import EC2DockCore
import SwiftUI

struct ServerRowView: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    let item: ServerListItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            FavoriteButton(isFavorite: item.profile.isFavorite) {
                state.toggleFavorite(id: item.id)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.profile.displayName)
                        .font(.headline)
                    StateBadge(state: item.stateLabel)
                    if terminals.sessions(for: item.id).contains(where: \.isRunning) {
                        Image(systemName: "terminal.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .help("내장 터미널로 연결 중")
                    }
                }
                Text("\(state.accountLabel(for: item.profile.accountID)) · \(item.profile.region)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let addresses {
                    Text(addresses)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if !item.profile.environment.isEmpty {
                        EnvironmentTag(environment: item.profile.environment, isProduction: item.profile.isProduction)
                    }
                    Text(item.profile.connectionType.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        // 중지/종료된 인스턴스는 흐리게 표시한다.
        .opacity(item.instance?.isRunning == true ? 1 : 0.55)
    }

    /// 예: "공인 203.0.113.25 · 사설 10.0.1.10"
    private var addresses: String? {
        let parts = [
            item.instance?.publicIPAddress.map { "공인 \($0)" },
            item.instance?.privateIPAddress.map { "사설 \($0)" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct FavoriteButton: View {
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? .yellow : .secondary)
        }
        .buttonStyle(.borderless)
        .help(isFavorite ? "즐겨찾기 해제" : "즐겨찾기 추가")
        .accessibilityLabel(isFavorite ? "즐겨찾기 해제" : "즐겨찾기 추가")
    }
}

struct StateBadge: View {
    let state: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(state)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch state {
        case "running": .green
        case "pending", "stopping", "shutting-down": .orange
        case "stopped": .gray
        case "terminated": .red
        default: .secondary
        }
    }
}

struct EnvironmentTag: View {
    let environment: String
    let isProduction: Bool

    var body: some View {
        Text(environment)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color { isProduction ? .red : .blue }
}
