import Foundation
import CmuxCore
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
    @Test("a new workspace is colored from the palette and restore colors the rest")
    func workspacesGetColors() throws {
        let manager = TabManager()
        let workspace = manager.addTab(select: true)
        let hex = try #require(workspace.customColor)
        #expect(WorkspaceTabColorSettings.palette().map { $0.hex.uppercased() }.contains(hex.uppercased()))

        workspace.setCustomColor(nil)
        #expect(workspace.customColor == nil)
        manager.assignWorkspaceColorsWhereMissing()
        #expect(workspace.customColor != nil)
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
