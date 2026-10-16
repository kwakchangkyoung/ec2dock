import Foundation
import Testing
@testable import EC2DockCore

@Suite("PaneLayout")
struct PaneLayoutTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func splittingSinglePaneCreatesSplit() {
        let root = PaneNode.pane(a).inserting(b, besides: a, axis: .horizontal)
        guard case .split(_, .horizontal, let children) = root else {
            Issue.record("expected split")
            return
        }
        #expect(children == [.pane(a), .pane(b)])
        #expect(root.paneIDs == [a, b])
    }

    /// 같은 방향으로 다시 나누면 중첩하지 않고 형제로 추가한다 (균등 분할).
    @Test func sameAxisSplitAddsSibling() {
        let root = PaneNode.pane(a)
            .inserting(b, besides: a, axis: .horizontal)
            .inserting(c, besides: a, axis: .horizontal)
        guard case .split(_, .horizontal, let children) = root else {
            Issue.record("expected split")
            return
        }
        #expect(children == [.pane(a), .pane(c), .pane(b)])
    }

    @Test func otherAxisSplitNests() {
        let root = PaneNode.pane(a)
            .inserting(b, besides: a, axis: .horizontal)
            .inserting(c, besides: b, axis: .vertical)
        #expect(root.paneIDs == [a, b, c])
        guard case .split(_, .horizontal, let children) = root, case .split(_, .vertical, let inner) = children[1] else {
            Issue.record("expected nested split")
            return
        }
        #expect(inner == [.pane(b), .pane(c)])
    }

    @Test func removingCollapsesSingleChildSplits() {
        let root = PaneNode.pane(a)
            .inserting(b, besides: a, axis: .horizontal)
            .inserting(c, besides: b, axis: .vertical)
        let afterC = root.removing(c)
        #expect(afterC?.paneIDs == [a, b])
        guard case .split(_, .horizontal, let children) = afterC else {
            Issue.record("expected split")
            return
        }
        #expect(children == [.pane(a), .pane(b)])   // 세로 분할은 접혀 b만 남는다
        #expect(afterC?.removing(a) == .pane(b))
        #expect(PaneNode.pane(a).removing(a) == nil)
    }

    @Test func replacingKeepsPosition() {
        let root = PaneNode.pane(a).inserting(b, besides: a, axis: .vertical)
        #expect(root.replacing(a, with: d).paneIDs == [d, b])
    }

    @Test func focusCyclesInScreenOrder() {
        var tab = TerminalTabLayout(firstPane: a)
        tab.root = tab.root.inserting(b, besides: a, axis: .horizontal).inserting(c, besides: b, axis: .vertical)
        #expect(tab.pane(after: a, offset: 1) == b)
        #expect(tab.pane(after: c, offset: 1) == a)
        #expect(tab.pane(after: a, offset: -1) == c)
        #expect(tab.contains(c))
        #expect(!tab.contains(d))
    }
}

@Suite("TerminalTabNavigation")
struct TerminalTabNavigationTests {
    let t1 = UUID(), t2 = UUID(), t3 = UUID()

    /// 순서: 서버 정보(nil) → 탭1 → 탭2 → 탭3 → 서버 정보
    @Test func adjacentCyclesThroughServerInfo() {
        let tabs = [t1, t2, t3]
        #expect(TerminalTabNavigation.adjacent(to: nil, offset: 1, tabs: tabs) == t1)
        #expect(TerminalTabNavigation.adjacent(to: t3, offset: 1, tabs: tabs) == nil)
        #expect(TerminalTabNavigation.adjacent(to: nil, offset: -1, tabs: tabs) == t3)
        #expect(TerminalTabNavigation.adjacent(to: t2, offset: -1, tabs: tabs) == t1)
    }

    @Test func numberedTabs() {
        let tabs = [t1, t2]
        #expect(TerminalTabNavigation.tab(number: 1, tabs: tabs) == .some(t1))
        #expect(TerminalTabNavigation.tab(number: 2, tabs: tabs) == .some(t2))
        #expect(TerminalTabNavigation.tab(number: 0, tabs: tabs) == .some(nil))   // 서버 정보
        #expect(TerminalTabNavigation.tab(number: 3, tabs: tabs) == nil)          // 없는 번호는 이동 안 함
    }
}
