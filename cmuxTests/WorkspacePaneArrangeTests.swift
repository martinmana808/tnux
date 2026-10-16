import Foundation
import Bonsplit
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for Spectacle-style grid arrangement of panes.
@Suite("Workspace pane grid arrangement")
struct WorkspacePaneArrangeTests {
    @Test("group sizes split evenly, larger groups first")
    func groupSizes() {
        #expect(PaneGridArrangement.groupSizes(count: 6, groups: 2) == [3, 3])
        #expect(PaneGridArrangement.groupSizes(count: 7, groups: 3) == [3, 2, 2])
        #expect(PaneGridArrangement.groupSizes(count: 2, groups: 3) == [1, 1], "never more groups than items")
        #expect(PaneGridArrangement.groupSizes(count: 0, groups: 2) == [])
    }

    /// Leaves of the tree grouped by the children of the root split, with the
    /// root orientation.
    @MainActor
    private func rootGroups(_ workspace: Workspace) -> (orientation: String, groups: [[String]]) {
        func leaves(_ node: ExternalTreeNode) -> [String] {
            switch node {
            case .pane(let pane): return [pane.id]
            case .split(let split): return leaves(split.first) + leaves(split.second)
            }
        }
        // The tree is a right-leaning chain: first, then (second, then ...).
        func chain(_ node: ExternalTreeNode, orientation: String) -> [ExternalTreeNode] {
            guard case .split(let split) = node, split.orientation.lowercased() == orientation else { return [node] }
            return [split.first] + chain(split.second, orientation: orientation)
        }
        guard case .split(let root) = workspace.bonsplitController.treeSnapshot() else { return ("", []) }
        let orientation = root.orientation.lowercased()
        let groups = chain(.split(root), orientation: orientation).map(leaves)
        return (orientation, groups)
    }

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
    @Test("six panes in two rows become two stacked rows of three")
    func sixPanesTwoRows() throws {
        let (workspace, panels) = try makeWorkspace(panes: 6)
        workspace.focusPanel(panels[4])

        #expect(workspace.arrangePanes(rows: 2))

        let (orientation, groups) = rootGroups(workspace)
        #expect(orientation == "vertical", "rows stack top to bottom")
        #expect(groups.map(\.count) == [3, 3])
        #expect(workspace.bonsplitController.allPaneIds.count == 6, "every surface keeps its own pane")
        #expect(Set(workspace.orderedPanelIds) == Set(panels), "nothing closed or created")
        #expect(workspace.focusedPanelId == panels[4], "focus returns to the pane that had it")
    }

    @MainActor
    @Test("seven panes in three columns become 3/2/2")
    func sevenPanesThreeColumns() throws {
        let (workspace, panels) = try makeWorkspace(panes: 7)

        #expect(workspace.arrangePanes(columns: 3))

        let (orientation, groups) = rootGroups(workspace)
        #expect(orientation == "horizontal", "columns sit side by side")
        #expect(groups.map(\.count) == [3, 2, 2])
        #expect(Set(workspace.orderedPanelIds) == Set(panels))
    }

    @MainActor
    @Test("a single pane has nothing to arrange")
    func singlePane() throws {
        let workspace = Workspace()
        #expect(!workspace.arrangePanes(rows: 2))
    }

    /// Each leaf's (width, height) as a fraction of the workspace, derived
    /// from the divider positions; the shape of the split chain does not
    /// matter, only what ends up on screen.
    @MainActor
    private func leafSizes(_ node: ExternalTreeNode, width: Double = 1, height: Double = 1) -> [(width: Double, height: Double)] {
        switch node {
        case .pane:
            return [(width, height)]
        case .split(let split):
            let position = Double(split.dividerPosition)
            if split.orientation.lowercased() == "horizontal" {
                return leafSizes(split.first, width: width * position, height: height)
                    + leafSizes(split.second, width: width * (1 - position), height: height)
            }
            return leafSizes(split.first, width: width, height: height * position)
                + leafSizes(split.second, width: width, height: height * (1 - position))
        }
    }

    @MainActor
    private func expectEvenGrid(_ workspace: Workspace, rowWidths: [Double], rowHeight: Double, label: String) {
        let sizes = leafSizes(workspace.bonsplitController.treeSnapshot())
        let got = sizes.map { "\(($0.width * 100).rounded() / 100)x\(($0.height * 100).rounded() / 100)" }.sorted()
        let want = rowWidths.map { "\(($0 * 100).rounded() / 100)x\((rowHeight * 100).rounded() / 100)" }.sorted()
        #expect(got == want, "\(label): leaves \(got) should be \(want)")
    }

    @MainActor
    @Test("arranging leaves every divider even, also after the layout settles")
    func arrangeEndsEqualized() throws {
        let (workspace, _) = try makeWorkspace(panes: 7)
        #expect(workspace.arrangePanes(rows: 3))
        // 3 rows of 1/3 height: one row of three cells (1/3 wide), two rows of two (1/2 wide).
        let widths: [Double] = [1.0 / 3, 1.0 / 3, 1.0 / 3, 0.5, 0.5, 0.5, 0.5]
        expectEvenGrid(workspace, rowWidths: widths, rowHeight: 1.0 / 3, label: "immediately")
        // The settle passes run on the main queue; let them fire and check nothing drifts.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        expectEvenGrid(workspace, rowWidths: widths, rowHeight: 1.0 / 3, label: "after settling")
    }
}
