import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The sidebar's pane rows: a value snapshot per window, plus the persisted
/// expand/view-all/sort choices shared with the menu and the palette.
@Suite("Sidebar panes")
struct SidebarPanesModelTests {
    @MainActor
    private func makeWorkspace(panes: Int) throws -> (Workspace, [UUID]) {
        let workspace = Workspace()
        var created = [try #require(workspace.orderedPanelIds.first)]
        for _ in 1..<panes {
            let paneId = try #require(workspace.bonsplitController.focusedPaneId)
            let panel = try #require(workspace.splitPaneWithNewTerminal(
                targetPane: paneId, orientation: .horizontal, insertFirst: false, workingDirectory: nil, initialInput: nil
            ))
            created.append(panel.id)
        }
        return (workspace, created)
    }

    @MainActor
    @Test("snapshot lists every pane in layout order and knows the focused one")
    func snapshotRows() throws {
        let (workspace, panels) = try makeWorkspace(panes: 3)
        workspace.focusPanel(panels[1])
        let now = Date()
        workspace.panelLastFocusedAt[panels[0]] = now.addingTimeInterval(-86_400 * 3)
        workspace.panelLastFocusedAt[panels[2]] = now

        let snapshot = SidebarPanesSnapshot.build(workspaces: [workspace], selectedWorkspaceId: workspace.id, now: now)
        #expect(snapshot.rows(for: workspace.id, sort: .layout).map(\.id) == panels)
        #expect(snapshot.focusedRowByWorkspace[workspace.id]?.id == panels[1])
        #expect(snapshot.rows(for: workspace.id, sort: .layout).map(\.isFocused) == [false, true, false])
        #expect(snapshot.rows(for: workspace.id, sort: .lastPrompted).map(\.id) == [panels[2], panels[0], panels[1]], "unknown age sinks to the bottom")
        #expect(snapshot.allRows.count == 3)
        #expect(snapshot.workspaceIds == [workspace.id])
        #expect(snapshot.builtAt <= now && now.timeIntervalSince(snapshot.builtAt) < 60, "rounded down to the minute")

        let unselected = SidebarPanesSnapshot.build(workspaces: [workspace], selectedWorkspaceId: nil, now: now)
        #expect(unselected.rows(for: workspace.id, sort: .layout).allSatisfy { !$0.isFocused }, "only the selected workspace's pane counts as focused")
        #expect(unselected.focusedRowByWorkspace[workspace.id]?.id == panels[1], "but the peek row is still known")
    }

    @MainActor
    @Test("snapshots built within the same minute compare equal")
    func snapshotEquality() {
        // 1_000_020 and 1_000_050 share the minute starting at 1_000_020; 1_000_080 starts the next one.
        let a = SidebarPanesSnapshot.build(workspaces: [], selectedWorkspaceId: nil, now: Date(timeIntervalSinceReferenceDate: 1_000_020))
        let b = SidebarPanesSnapshot.build(workspaces: [], selectedWorkspaceId: nil, now: Date(timeIntervalSinceReferenceDate: 1_000_050))
        let c = SidebarPanesSnapshot.build(workspaces: [], selectedWorkspaceId: nil, now: Date(timeIntervalSinceReferenceDate: 1_000_080))
        #expect(a == b)
        #expect(a != c)
    }

    @MainActor
    @Test("preferences persist expanded workspaces, view all and sort")
    func preferences() throws {
        let suite = "SidebarPanesModelTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = UUID(), b = UUID()

        let preferences = SidebarPanesPreferences(defaults: defaults)
        #expect(preferences.expandedWorkspaceIds.isEmpty, "collapsed by default")
        #expect(preferences.viewAll == false)
        #expect(preferences.sort == .layout)

        preferences.toggle(a)
        #expect(preferences.isExpanded(a))
        #expect(!preferences.allExpanded([a, b]))
        preferences.toggleAll([a, b])
        #expect(preferences.allExpanded([a, b]), "toggle all expands when any is collapsed")
        preferences.toggleAll([a, b])
        #expect(preferences.expandedWorkspaceIds.isEmpty, "and collapses when all are expanded")
        preferences.expandAll([b])
        preferences.viewAll = true
        preferences.sort = .lastPrompted

        let reloaded = SidebarPanesPreferences(defaults: defaults)
        #expect(reloaded.expandedWorkspaceIds == [b])
        #expect(reloaded.viewAll)
        #expect(reloaded.sort == .lastPrompted)
    }
}
