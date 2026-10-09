import Foundation
import CmuxCore
import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Tnux menus, shortcuts, and workspace colors")
struct TnuxMenusAndColorsTests {
    @Test("pane status classification prefers needs-input, then running, then idle")
    func paneStatusClassification() {
        #expect(PaneMenuEntry.status(from: ["Needs input"], hasAgent: true) == .needsInput)
        #expect(PaneMenuEntry.status(from: ["Running", "Claude is waiting for your input"], hasAgent: true) == .needsInput)
        #expect(PaneMenuEntry.status(from: ["Running"], hasAgent: true) == .running)
        #expect(PaneMenuEntry.status(from: [], hasAgent: true) == .idle)
        #expect(PaneMenuEntry.status(from: [], hasAgent: false) == .none)
    }

    @Test("auto workspace color picks the least-used palette entry in palette order")
    func autoColorLeastUsed() {
        let palette = ["#AA0000", "#00AA00", "#0000AA"]
        #expect(WorkspaceAutoColor.nextHex(palette: palette, used: []) == "#AA0000")
        #expect(WorkspaceAutoColor.nextHex(palette: palette, used: ["#aa0000"]) == "#00AA00")
        #expect(WorkspaceAutoColor.nextHex(palette: palette, used: ["#AA0000", "#00AA00", "#0000AA", "#AA0000"]) == "#00AA00")
        #expect(WorkspaceAutoColor.nextHex(palette: [], used: []) == nil)
    }

    @MainActor
    @Test("workspaces have no color by default; coloring is opt-in and the one-time clear only runs once")
    func workspacesUncoloredByDefault() throws {
        let manager = TabManager()
        let workspace = manager.addTab(select: true)
        #expect(workspace.customColor == nil, "no automatic color")

        manager.assignWorkspaceColorsWhereMissing()
        let hex = try #require(workspace.customColor)
        #expect(WorkspaceTabColorSettings.palette().map { $0.hex.uppercased() }.contains(hex.uppercased()))

        let defaults = UserDefaults(suiteName: "tnux-tests-\(UUID().uuidString)")!
        manager.clearAutoAssignedWorkspaceColorsOnce(defaults: defaults)
        #expect(workspace.customColor == nil, "first run clears auto colors")
        workspace.setCustomColor("#C0392B")
        manager.clearAutoAssignedWorkspaceColorsOnce(defaults: defaults)
        #expect(workspace.customColor == "#C0392B", "later runs leave hand-picked colors alone")
    }

    @Test("history rows read folder — pane - workspace")
    func historyTitleCarriesProjectFolder() {
        let item = FocusHistoryMenuItem(
            historyIndex: 0,
            entry: FocusHistoryEntry(workspaceId: UUID(), panelId: UUID()),
            workspaceTitle: "F925",
            panelTitle: "✳ Proposal audit against RFP",
            position: .older,
            focusedAt: Date(),
            isNavigable: true
        )
        #expect(FocusHistoryMenuFormatter.title(for: item, projectSegment: "f925-26") == "f925-26 — ✳ Proposal audit against RFP - F925")
        #expect(FocusHistoryMenuFormatter.title(for: item, projectSegment: nil) == "✳ Proposal audit against RFP - F925")
        let prefixed = FocusHistoryMenuItem(
            historyIndex: 0, entry: item.entry, workspaceTitle: "F925", panelTitle: "f925-26 — shell",
            position: .older, focusedAt: Date(), isNavigable: true
        )
        #expect(FocusHistoryMenuFormatter.title(for: prefixed, projectSegment: "f925-26") == "f925-26 — shell - F925", "no double prefix")
    }

    @Test("arrange shortcuts default to Cmd+Ctrl+digit and Cmd+Option+digit")
    func arrangeShortcutDefaults() {
        #expect(KeyboardShortcutSettings.Action.arrangePanesRowsByNumber.defaultShortcut
            == StoredShortcut(key: "1", command: true, shift: false, option: false, control: true))
        #expect(KeyboardShortcutSettings.Action.arrangePanesColumnsByNumber.defaultShortcut
            == StoredShortcut(key: "1", command: true, shift: false, option: true, control: false))
        #expect(KeyboardShortcutSettings.Action.arrangePanesRowsByNumber.usesNumberedDigitMatching)
        #expect(KeyboardShortcutSettings.Action.arrangePanesColumnsByNumber.usesNumberedDigitMatching)
    }
}
