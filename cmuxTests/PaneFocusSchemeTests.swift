import AppKit
import Foundation
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for the focused-pane color scheme and tab aging markers.
@Suite("Pane focus scheme and aging")
struct PaneFocusSchemeTests {
    @Test("activation darkens the theme background a tad and only touches the background")
    func activationSequenceShape() {
        let theme = NSColor(calibratedRed: 0x20 / 255, green: 0x20 / 255, blue: 0x20 / 255, alpha: 1)
        let text = String(decoding: PaneFocusColorScheme.activationSequence(themeBackground: theme), as: UTF8.self)
        #expect(text == "\u{1B}]11;#1C1C1C\u{07}", "0x20 scaled by 0.88 is 0x1C; no foreground or palette changes")
        #expect(PaneFocusColorScheme.hex(PaneFocusColorScheme.darkened(.white)) == "E0E0E0")
    }

    @Test("deactivation resets only the background")
    func deactivationSequenceShape() {
        #expect(String(decoding: PaneFocusColorScheme.deactivationSequence, as: UTF8.self) == "\u{1B}]111\u{07}")
    }

    @MainActor
    @Test("focusing a pane stamps its last-focus time and marks the scheme active")
    func focusStampsLastFocusedAt() throws {
        let workspace = Workspace(workingDirectory: "/tmp")
        let panel = try #require(workspace.focusedTerminalPanel)
        #expect(workspace.panelLastFocusedAt[panel.id] == nil)

        let before = Date()
        workspace.applyPaneFocusScheme(panelId: panel.id, active: true)
        let stamped = try #require(workspace.panelLastFocusedAt[panel.id])
        #expect(stamped >= before)
        #expect(workspace.paneFocusSchemeActivePanelIds.contains(panel.id))

        workspace.applyPaneFocusScheme(panelId: panel.id, active: false)
        #expect(!workspace.paneFocusSchemeActivePanelIds.contains(panel.id))
        #expect(workspace.panelLastFocusedAt[panel.id] == stamped, "losing focus keeps the last-focus time")
    }

    @MainActor
    @Test("last-focus time round-trips through the session snapshot")
    func lastFocusedAtRoundTrips() throws {
        let workspace = Workspace(workingDirectory: "/tmp")
        let panel = try #require(workspace.focusedTerminalPanel)
        let focusedAt = Date(timeIntervalSince1970: 1_790_000_000)
        workspace.panelLastFocusedAt[panel.id] = focusedAt

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(snapshot.panels.first { $0.id == panel.id })
        #expect(panelSnapshot.lastFocusedAt == focusedAt.timeIntervalSince1970)

        let restored = Workspace()
        let restoredIds = restored.restoreSessionSnapshot(snapshot)
        let restoredId = try #require(restoredIds[panel.id])
        #expect(restored.panelLastFocusedAt[restoredId] == focusedAt)
    }
}
