import Foundation

/// 분할 방향
public enum SplitAxis: Sendable {
    /// 좌우로 나란히
    case horizontal
    /// 위아래로
    case vertical
}

/// 터미널 탭 안의 분할 배치. 잎(pane)은 세션 ID다.
public indirect enum PaneNode: Identifiable, Equatable, Sendable {
    case pane(UUID)
    case split(id: UUID, axis: SplitAxis, children: [PaneNode])

    public var id: UUID {
        switch self {
        case .pane(let id): id
        case .split(let id, _, _): id
        }
    }

    /// 화면 순서(왼쪽→오른쪽, 위→아래)의 세션 ID
    public var paneIDs: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let children): children.flatMap(\.paneIDs)
        }
    }

    /// `target` 옆에 `newPane`을 넣는다. 같은 방향 분할 안이면 형제로 추가해 균등하게 나눈다.
    public func inserting(_ newPane: UUID, besides target: UUID, axis: SplitAxis) -> PaneNode {
        switch self {
        case .pane(let id):
            guard id == target else { return self }
            return .split(id: UUID(), axis: axis, children: [.pane(id), .pane(newPane)])
        case .split(let id, let splitAxis, let children):
            if splitAxis == axis, let index = children.firstIndex(of: .pane(target)) {
                var updated = children
                updated.insert(.pane(newPane), at: index + 1)
                return .split(id: id, axis: splitAxis, children: updated)
            }
            return .split(id: id, axis: splitAxis,
                          children: children.map { $0.inserting(newPane, besides: target, axis: axis) })
        }
    }

    /// 칸을 제거한다. 자식이 하나만 남은 분할은 그 자식으로 접는다. 모두 사라지면 nil.
    public func removing(_ target: UUID) -> PaneNode? {
        switch self {
        case .pane(let id):
            return id == target ? nil : self
        case .split(let id, let axis, let children):
            let remaining = children.compactMap { $0.removing(target) }
            switch remaining.count {
            case 0: return nil
            case 1: return remaining[0]
            default: return .split(id: id, axis: axis, children: remaining)
            }
        }
    }

    public func replacing(_ old: UUID, with new: UUID) -> PaneNode {
        switch self {
        case .pane(let id):
            return id == old ? .pane(new) : self
        case .split(let id, let axis, let children):
            return .split(id: id, axis: axis, children: children.map { $0.replacing(old, with: new) })
        }
    }
}

/// 내장 터미널 탭 하나: 분할 배치와 포커스된 칸
public struct TerminalTabLayout: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var root: PaneNode
    public var focusedPaneID: UUID

    public init(id: UUID = UUID(), firstPane: UUID) {
        self.id = id
        self.root = .pane(firstPane)
        self.focusedPaneID = firstPane
    }

    public func contains(_ paneID: UUID) -> Bool {
        root.paneIDs.contains(paneID)
    }

    /// 포커스를 화면 순서로 `offset`만큼 옮긴다 (끝에서는 반대쪽으로 돈다).
    public func pane(after paneID: UUID, offset: Int) -> UUID {
        let ids = root.paneIDs
        guard let index = ids.firstIndex(of: paneID), !ids.isEmpty else { return ids.first ?? paneID }
        return ids[((index + offset) % ids.count + ids.count) % ids.count]
    }
}

/// 탭 이동
public enum TerminalTabNavigation {
    /// 터미널 탭끼리 `offset`만큼 이동한다 (끝에서는 반대쪽으로 돈다).
    /// "서버 정보"(nil)는 순환에 넣지 않는다 — 지나갈 때마다 화면 구성이 바뀌기 때문이다(⌘0으로 이동).
    /// 서버 정보에서 시작하면 앞으로는 첫 탭, 뒤로는 마지막 탭으로 간다. 탭이 없으면 nil.
    public static func adjacent(to current: UUID?, offset: Int, tabs: [UUID]) -> UUID? {
        guard !tabs.isEmpty else { return nil }
        guard let current, let index = tabs.firstIndex(of: current) else {
            return offset >= 0 ? tabs.first : tabs.last
        }
        return tabs[((index + offset) % tabs.count + tabs.count) % tabs.count]
    }

    /// ⌘1~⌘9: n번째 터미널 탭, ⌘0: 서버 정보. 없는 번호면 nil을 돌려주고 이동하지 않는다.
    public static func tab(number: Int, tabs: [UUID]) -> UUID?? {
        if number == 0 { return .some(nil) }
        guard tabs.indices.contains(number - 1) else { return nil }
        return .some(tabs[number - 1])
    }
}
