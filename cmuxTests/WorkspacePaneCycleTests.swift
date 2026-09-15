import Foundation
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for "Focus Next Pane" / "Focus Previous Pane": cycling in
/// layout order with wrap-around, and carrying an active pane zoom along so
/// the shortcut keeps working while one pane fills the window.
@Suite("Workspace pane cycling")
struct WorkspacePaneCycleTests {
    @MainActor
    private func makeTwoPaneWorkspace() throws -> (workspace: Workspace, firstPanelId: UUID, secondPanelId: UUID) {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.orderedPanelIds.first)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let secondPanel = try #require(
            workspace.splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: .horizontal,
                insertFirst: false,
                workingDirectory: nil,
                initialInput: nil
            )
        )
        workspace.focusPanel(firstPanelId)
        #expect(workspace.focusedPanelId == firstPanelId)
        return (workspace, firstPanelId, secondPanel.id)
    }

    @MainActor
    @Test("next and previous cycle panes in layout order and wrap at the ends")
    func cyclesPanesWithWrapAround() throws {
        let (workspace, first, second) = try makeTwoPaneWorkspace()

        #expect(workspace.focusAdjacentPane(offset: 1))
        #expect(workspace.focusedPanelId == second)

        #expect(workspace.focusAdjacentPane(offset: 1))
        #expect(workspace.focusedPanelId == first, "next from the last pane wraps to the first")

        #expect(workspace.focusAdjacentPane(offset: -1))
        #expect(workspace.focusedPanelId == second, "previous from the first pane wraps to the last")
    }

    @MainActor
    @Test("a zoomed pane hands the zoom to the newly focused pane")
    func zoomFollowsCycledFocus() throws {
        let (workspace, first, second) = try makeTwoPaneWorkspace()
        let firstPaneId = try #require(workspace.paneId(forPanelId: first))
        let secondPaneId = try #require(workspace.paneId(forPanelId: second))

        #expect(workspace.toggleSplitZoom(panelId: first))
        #expect(workspace.bonsplitController.zoomedPaneId == firstPaneId)

        #expect(workspace.focusAdjacentPane(offset: 1))
        #expect(workspace.focusedPanelId == second)
        #expect(workspace.bonsplitController.isSplitZoomed, "zoom stays active across the cycle")
        #expect(workspace.bonsplitController.zoomedPaneId == secondPaneId, "zoom moved to the focused pane")

        #expect(workspace.focusAdjacentPane(offset: -1))
        #expect(workspace.focusedPanelId == first)
        #expect(workspace.bonsplitController.zoomedPaneId == firstPaneId)
    }

    @MainActor
    @Test("a single pane has nothing to cycle to")
    func singlePaneReturnsFalse() throws {
        let workspace = Workspace()
        let only = try #require(workspace.focusedPanelId)
        #expect(!workspace.focusAdjacentPane(offset: 1))
        #expect(workspace.focusedPanelId == only)
    }

    @Test("pane cycling defaults to Ctrl+Shift+Option+Arrow")
    func defaultShortcuts() {
        #expect(
            KeyboardShortcutSettings.Action.focusNextPane.defaultShortcut
                == StoredShortcut(key: "→", command: false, shift: true, option: true, control: true)
        )
        #expect(
            KeyboardShortcutSettings.Action.focusPreviousPane.defaultShortcut
                == StoredShortcut(key: "←", command: false, shift: true, option: true, control: true)
        )
    }
}
