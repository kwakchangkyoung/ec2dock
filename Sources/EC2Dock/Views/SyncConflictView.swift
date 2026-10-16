import EC2DockCore
import SwiftUI

/// iCloud 동기화 충돌 해결 (설계서 9.3).
/// 다른 항목만 나란히 보여주고, 이 Mac 버전과 iCloud 버전 중 하나를 고르게 한다.
/// 직접 병합이 필요하면 한쪽을 고른 뒤 "접속 설정 편집"에서 고치면 된다.
struct SyncConflictView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @ViewState private var isResolving = false

    var body: some View {
        VStack(spacing: 0) {
            if state.syncConflicts.isEmpty {
                ContentUnavailableView("충돌이 없습니다", systemImage: "checkmark.icloud")
            } else {
                List {
                    Text("이 Mac과 다른 Mac에서 같은 서버를 서로 다르게 수정했습니다. 남길 버전을 고르세요. 고르지 않은 쪽의 변경은 사라집니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(state.syncConflicts) { conflict in
                        conflictRow(conflict)
                    }
                }
            }
            Divider()
            HStack {
                if isResolving { ProgressView().controlSize(.small) }
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 620, height: 480)
    }

    private func conflictRow(_ conflict: SyncConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(conflict.local.displayName).font(.headline)
            Text("\(conflict.local.accountAlias) · \(conflict.local.region) · \(conflict.local.instanceID)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("항목").foregroundStyle(.secondary)
                    Text("이 Mac").foregroundStyle(.secondary)
                    Text("iCloud").foregroundStyle(.secondary)
                }
                .font(.caption)
                ForEach(conflict.differences, id: \.label) { difference in
                    GridRow {
                        Text(difference.label)
                        Text(difference.local).fontWeight(.medium)
                        Text(difference.remote).fontWeight(.medium)
                    }
                }
                GridRow {
                    Text("수정 시각").foregroundStyle(.secondary)
                    Text(conflict.local.updatedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    Text(conflict.remote.updatedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            HStack {
                Button("이 Mac 버전 사용") { resolve(conflict, .keepLocal) }
                Button("iCloud 버전 사용") { resolve(conflict, .keepRemote) }
            }
            .disabled(isResolving)
        }
        .padding(.vertical, 6)
    }

    private func resolve(_ conflict: SyncConflict, _ resolution: AppState.SyncResolution) {
        Task {
            isResolving = true
            await state.resolveConflict(id: conflict.id, keep: resolution)
            isResolving = false
        }
    }
}
