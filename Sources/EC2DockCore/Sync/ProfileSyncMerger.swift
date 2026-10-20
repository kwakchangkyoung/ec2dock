import Foundation

extension ServerProfile {
    /// 생성/수정 시각을 제외한 내용이 같은지. 시각만 다른 경우는 변경으로 보지 않는다.
    public func hasSameContent(as other: ServerProfile) -> Bool {
        var lhs = self
        var rhs = other
        lhs.createdAt = .distantPast
        lhs.updatedAt = .distantPast
        rhs.createdAt = .distantPast
        rhs.updatedAt = .distantPast
        return lhs == rhs
    }

    /// 자동 발견 이후 사용자가 한 번도 수정하지 않은 프로필
    var isPristine: Bool { createdAt == updatedAt }
}

/// 이 Mac과 iCloud에서 같은 서버를 서로 다르게 수정한 경우
public struct SyncConflict: Identifiable, Equatable, Sendable {
    public struct FieldDifference: Equatable, Sendable {
        public let label: String
        public let local: String
        public let remote: String
    }

    public let local: ServerProfile
    public let remote: ServerProfile

    public var id: String { local.id }

    /// 화면에 보여줄 값이 다른 항목
    public var differences: [FieldDifference] {
        func describe(_ profile: ServerProfile) -> [(String, String)] {
            [
                ("표시 이름", profile.displayName),
                ("계정 별칭", profile.accountAlias),
                ("환경", profile.environment),
                ("그룹", profile.groupName),
                ("즐겨찾기", profile.isFavorite ? "예" : "아니요"),
                ("접속 방식", profile.connectionType.displayName),
                ("SSH 사용자", profile.sshUsername),
                ("SSH 포트", String(profile.sshPort)),
                ("Bastion", profile.bastionProfileID ?? "-"),
            ]
        }
        return zip(describe(local), describe(remote)).compactMap { lhs, rhs in
            lhs.1 == rhs.1 ? nil : FieldDifference(label: lhs.0, local: lhs.1, remote: rhs.1)
        }
    }
}

public struct SyncMergeResult: Equatable, Sendable {
    /// 이 Mac에 반영할 목록 (충돌 항목은 이 Mac 값을 유지)
    public var local: [ServerProfile]
    /// iCloud에 쓸 목록 (충돌 항목은 iCloud 값을 유지)
    public var remote: [ServerProfile]
    /// 다음 비교 기준 (충돌 항목은 이전 기준을 유지)
    public var base: [ServerProfile]
    public var conflicts: [SyncConflict]
    /// 양쪽에 함께 둘 삭제 기록
    public var deleted: [ProfileTombstone] = []
}

/// 마지막 동기화 시점(base)을 기준으로 한 3-way 병합 (설계서 9.3).
/// 수정 시각만 비교해 조용히 덮어쓰지 않는다. 양쪽이 모두 바뀌면 충돌로 남긴다.
/// 한쪽 목록에 없다는 것만으로는 삭제로 보지 않는다. 파일 읽기 실패, 아직 내려받지 않은 파일,
/// 오래된 오프라인 파일 버전도 "없음"으로 보이기 때문이다. 삭제는 삭제 기록(`ProfileTombstone`)으로만 전파하며,
/// 삭제한 뒤에 수정(또는 복원)한 프로필은 삭제 기록보다 우선한다.
public enum ProfileSyncMerger {
    /// `remoteMayBeStale`: remote가 오래된 오프라인 파일 버전일 수 있을 때 true.
    /// 이때는 기준보다 오래된 remote 값을 새 변경으로 보지 않는다(최신 수정을 되돌리지 않도록).
    /// 주 문서에는 쓰지 않는다 — Mac마다 시계가 조금씩 달라 정상적인 수정을 오래된 값으로 오인할 수 있다.
    public static func merge(local: [ServerProfile], remote: [ServerProfile], base: [ServerProfile],
                             localDeleted: [ProfileTombstone] = [], remoteDeleted: [ProfileTombstone] = [],
                             remoteMayBeStale: Bool = false) -> SyncMergeResult {
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var deletedByID = Dictionary((localDeleted + remoteDeleted).map { ($0.id, $0) },
                                     uniquingKeysWith: { $0.deletedAt >= $1.deletedAt ? $0 : $1 })

        var mergedLocal = localByID
        var mergedRemote = remoteByID
        var mergedBase = baseByID
        var conflicts: [SyncConflict] = []

        for id in Set(localByID.keys).union(remoteByID.keys).union(baseByID.keys) {
            let baseProfile = baseByID[id]
            let present = [localByID[id], remoteByID[id]].compactMap { $0 }
            // 남아 있는 값보다 나중에 삭제되었으면 양쪽에서 지운다.
            if let tombstone = deletedByID[id], let latest = present.map(\.updatedAt).max(), tombstone.deletedAt >= latest {
                mergedLocal.removeValue(forKey: id)
                mergedRemote.removeValue(forKey: id)
                mergedBase.removeValue(forKey: id)
                continue
            }
            if !present.isEmpty { deletedByID.removeValue(forKey: id) }

            switch (localByID[id], remoteByID[id]) {
            case (let l?, nil):
                // 이 Mac에만 있다: iCloud에 올린다.
                mergedRemote[id] = l
                mergedBase[id] = l
            case (nil, let r?):
                // iCloud에만 있다: 이 Mac에 받는다.
                mergedLocal[id] = r
                mergedBase[id] = r
            case (let l?, let r?):
                switch resolve(local: l, remote: r, base: baseProfile, remoteMayBeStale: remoteMayBeStale) {
                case .same:
                    mergedBase[id] = l
                case .takeLocal:
                    mergedRemote[id] = l
                    mergedBase[id] = l
                case .takeRemote:
                    mergedLocal[id] = r
                    mergedBase[id] = r
                case .conflict:
                    conflicts.append(SyncConflict(local: l, remote: r))
                }
            case (nil, nil):
                mergedBase.removeValue(forKey: id)
            }
        }

        return SyncMergeResult(
            local: ordered(mergedLocal, preferring: local, then: remote),
            remote: ordered(mergedRemote, preferring: remote, then: local),
            base: ordered(mergedBase, preferring: base, then: local + remote),
            conflicts: conflicts.sorted { $0.local.displayName.localizedStandardCompare($1.local.displayName) == .orderedAscending },
            deleted: deletedByID.values.sorted { $0.id < $1.id }
        )
    }

    private enum Decision { case same, takeLocal, takeRemote, conflict }

    private static func resolve(local l: ServerProfile, remote r: ServerProfile, base b: ServerProfile?,
                                remoteMayBeStale: Bool) -> Decision {
        if l.hasSameContent(as: r) { return .same }
        if let b {
            let localChanged = !l.hasSameContent(as: b)
            let remoteChanged = !r.hasSameContent(as: b) && !(remoteMayBeStale && r.updatedAt < b.updatedAt)
            if !localChanged && remoteChanged { return .takeRemote }
            if !remoteChanged { return .takeLocal }
            return .conflict
        }
        // 처음 동기화: 한쪽이 자동 발견된 그대로라면 사용자가 수정한 쪽을 쓴다.
        switch (l.isPristine, r.isPristine) {
        case (true, false): return .takeRemote
        case (false, true): return .takeLocal
        case (true, true): return r.updatedAt > l.updatedAt ? .takeRemote : .takeLocal
        case (false, false): return .conflict
        }
    }

    /// 기존 순서를 최대한 유지한다.
    private static func ordered(_ byID: [String: ServerProfile], preferring first: [ServerProfile], then second: [ServerProfile]) -> [ServerProfile] {
        var seen = Set<String>()
        var result: [ServerProfile] = []
        for profile in first + second where seen.insert(profile.id).inserted {
            if let merged = byID[profile.id] { result.append(merged) }
        }
        return result
    }
}
