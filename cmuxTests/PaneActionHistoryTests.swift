import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Focus Back / Forward and Recent Actions walk panes by the user's last
/// action, never by focus.
@Suite("Pane action history")
struct PaneActionHistoryTests {
    private func entry(_ id: UUID, _ secondsAgo: TimeInterval, now: Date = Date()) -> PaneActionHistoryEntry {
        PaneActionHistoryEntry(id: id, workspaceId: UUID(), workspaceTitle: "ws", title: "t", lastActionAt: now.addingTimeInterval(-secondsAgo))
    }

    @Test("back walks to older actions, forward to newer, from outside the list to the newest")
    func targetIndex() {
        let a = UUID(), b = UUID(), c = UUID(), stranger = UUID()
        let entries = [entry(a, 10), entry(b, 100), entry(c, 1000)]
        #expect(PaneActionHistory.targetIndex(entries: entries, focusedPanelId: a, direction: .back) == 1)
        #expect(PaneActionHistory.targetIndex(entries: entries, focusedPanelId: b, direction: .back) == 2)
        #expect(PaneActionHistory.targetIndex(entries: entries, focusedPanelId: c, direction: .back) == nil, "nothing older")
        #expect(PaneActionHistory.targetIndex(entries: entries, focusedPanelId: stranger, direction: .back) == 0, "a pane you never acted in jumps to the last action")
        #expect(PaneActionHistory.targetIndex(entries: entries, focusedPanelId: nil, direction: .back) == 0)
        #expect(PaneActionHistory.targetIndex(entries: entries, focusedPanelId: c, direction: .forward) == 1)
        #expect(PaneActionHistory.targetIndex(entries: entries, focusedPanelId: a, direction: .forward) == nil, "already at the newest")
        #expect(PaneActionHistory.targetIndex(entries: entries, focusedPanelId: stranger, direction: .forward) == nil)
        #expect(PaneActionHistory.targetIndex(entries: [], focusedPanelId: a, direction: .back) == nil)
    }

    @MainActor
    @Test("entries are ordered by last action and skip panes without one; focus alone changes nothing")
    func entriesFromWorkspace() throws {
        let workspace = Workspace()
        let first = try #require(workspace.orderedPanelIds.first)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let second = try #require(workspace.splitPaneWithNewTerminal(
            targetPane: paneId, orientation: .horizontal, insertFirst: false, workingDirectory: nil, initialInput: nil
        )).id
        let third = try #require(workspace.splitPaneWithNewTerminal(
            targetPane: paneId, orientation: .horizontal, insertFirst: false, workingDirectory: nil, initialInput: nil
        )).id
        let now = Date()
        workspace.panelLastFocusedAt[first] = now.addingTimeInterval(-3600)
        workspace.panelLastFocusedAt[second] = now
        workspace.panelLastFocusedAt[third] = nil

        var entries = PaneActionHistory.entries(workspaces: [workspace])
        #expect(entries.map(\.id) == [second, first])
        #expect(entries.allSatisfy { $0.workspaceId == workspace.id })

        workspace.focusPanel(third)
        entries = PaneActionHistory.entries(workspaces: [workspace])
        #expect(entries.map(\.id) == [second, first], "focusing a pane is not an action")

        workspace.notePaneAction(panelId: first, at: now.addingTimeInterval(60))
        entries = PaneActionHistory.entries(workspaces: [workspace])
        #expect(entries.map(\.id) == [first, second], "acting moves the pane to the top")
    }

    @MainActor
    @Test("menu rows read pane first, then workspace, with the last action time")
    func formatter() {
        let entry = PaneActionHistoryEntry(id: UUID(), workspaceId: UUID(), workspaceTitle: "Proyectos", title: "golf — Scoring", lastActionAt: Date().addingTimeInterval(-90))
        let title = PaneActionHistoryFormatter.menuTitle(for: entry)
        #expect(title.hasPrefix("golf — Scoring - Proyectos"))
        #expect(title.contains("\n"))
    }
}
