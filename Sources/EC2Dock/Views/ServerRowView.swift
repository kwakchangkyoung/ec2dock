import EC2DockCore
import SwiftUI

struct ServerRowView: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    let item: ServerListItem
    var density: ServerListDensity = .comfortable

    var body: some View {
        Group {
            switch density {
            case .comfortable: comfortable
            case .compact: compact
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// 기본 보기: 이름·상태 / 계정·리전 / IP / 환경·접속 방식
    private var comfortable: some View {
        HStack(alignment: .top, spacing: 8) {
            FavoriteButton(isFavorite: item.profile.isFavorite) {
                state.toggleFavorite(id: item.id)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.profile.displayName)
                        .font(.headline)
                        .foregroundStyle(isRunning ? .primary : .secondary)
                    StateBadge(state: item.stateLabel)
                    connectedIndicator
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
    }

    /// 간결 보기: 한 줄에 상태 점·이름·환경·주 IP
    private var compact: some View {
        HStack(spacing: 6) {
            FavoriteButton(isFavorite: item.profile.isFavorite) {
                state.toggleFavorite(id: item.id)
            }
            Circle()
                .fill(StateBadge.color(for: item.stateLabel))
                .frame(width: 7, height: 7)
                .help(item.stateLabel)
            Text(item.profile.displayName)
                .lineLimit(1)
                .foregroundStyle(isRunning ? .primary : .secondary)
            connectedIndicator
            Spacer(minLength: 4)
            if item.profile.isProduction {
                Text("PROD").font(.caption2.weight(.bold)).foregroundStyle(.red)
            }
            Text(primaryAddress ?? "-")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var connectedIndicator: some View {
        if terminals.sessions(for: item.id).contains(where: \.isRunning) {
            Image(systemName: "terminal.fill")
                .font(.caption)
                .foregroundStyle(.tint)
                .help("내장 터미널로 연결 중")
        }
    }

    private var isRunning: Bool { item.instance?.isRunning == true }

    /// 예: "공인 203.0.113.25 · 사설 10.0.1.10"
    private var addresses: String? {
        let parts = [
            item.instance?.publicIPAddress.map { "공인 \($0)" },
            item.instance?.privateIPAddress.map { "사설 \($0)" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 간결 보기에서는 접속 방식에 맞는 주소 하나만 보여준다.
    private var primaryAddress: String? {
        switch item.profile.connectionType {
        case .directSSH: item.instance?.publicIPAddress ?? item.instance?.privateIPAddress
        case .bastionSSH, .ssm: item.instance?.privateIPAddress
        }
    }

    private var accessibilitySummary: String {
        var parts = [item.profile.displayName, "상태 \(item.stateLabel)"]
        if item.profile.isFavorite { parts.append("즐겨찾기") }
        if !item.profile.environment.isEmpty { parts.append(item.profile.environment) }
        if let addresses { parts.append(addresses) }
        return parts.joined(separator: ", ")
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

    private var color: Color { Self.color(for: state) }

    static func color(for state: String) -> Color {
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
