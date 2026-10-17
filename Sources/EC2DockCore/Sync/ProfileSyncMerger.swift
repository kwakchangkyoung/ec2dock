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
}

/// 마지막 동기화 시점(base)을 기준으로 한 3-way 병합 (설계서 9.3).
/// 수정 시각만 비교해 조용히 덮어쓰지 않는다. 양쪽이 모두 바뀌면 충돌로 남긴다.
/// base에 있던 프로필이 한쪽에서 삭제되었고 다른 쪽에서 변경되지 않은 경우 삭제를 전파한다.
public enum ProfileSyncMerger {
    public static func merge(local: [ServerProfile], remote: [ServerProfile], base: [ServerProfile]) -> SyncMergeResult {
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var mergedLocal = localByID
        var mergedRemote = remoteByID
        var mergedBase = baseByID
        var conflicts: [SyncConflict] = []

        for id in Set(localByID.keys).union(remoteByID.keys).union(baseByID.keys) {
            let baseProfile = baseByID[id]
            switch (localByID[id], remoteByID[id]) {
            case (let l?, nil):
                if let b = baseProfile, l.hasSameContent(as: b) {
                    // remote에서 삭제되었고 local은 base와 같으므로 삭제 전파
                    mergedLocal.removeValue(forKey: id)
                    mergedBase.removeValue(forKey: id)
                } else {
                    // local에서 새로 추가되었거나, remote에서 삭제되었지만 local에서 수정된 경우
                    mergedRemote[id] = l
                    mergedBase[id] = l
                }
            case (nil, let r?):
                if let b = baseProfile, r.hasSameContent(as: b) {
                    // local에서 삭제되었고 remote는 base와 같으므로 삭제 전파
                    mergedRemote.removeValue(forKey: id)
                    mergedBase.removeValue(forKey: id)
                } else {
                    // remote에서 새로 추가되었거나, local에서 삭제되었지만 remote에서 수정된 경우
                    mergedLocal[id] = r
                    mergedBase[id] = r
                }
            case (let l?, let r?):
                switch resolve(local: l, remote: r, base: baseProfile) {
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
            conflicts: conflicts.sorted { $0.local.displayName.localizedStandardCompare($1.local.displayName) == .orderedAscending }
        )
    }

    private enum Decision { case same, takeLocal, takeRemote, conflict }

    private static func resolve(local l: ServerProfile, remote r: ServerProfile, base b: ServerProfile?) -> Decision {
        if l.hasSameContent(as: r) { return .same }
        if let b {
            let localChanged = !l.hasSameContent(as: b)
            let remoteChanged = !r.hasSameContent(as: b)
            if !localChanged { return .takeRemote }
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
