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
    @Test("activation paints black text, the pane color, and a full dark palette")
    func activationSequenceShape() {
        let color = NSColor(calibratedRed: 0xF3 / 255, green: 0xB9 / 255, blue: 0xAF / 255, alpha: 1)
        let text = String(decoding: PaneFocusColorScheme.activationSequence(background: color), as: UTF8.self)
        #expect(text.contains("\u{1B}]10;#000000\u{07}"), "default foreground goes black")
        #expect(text.contains("\u{1B}]11;#F3B9AF\u{07}"), "background is the pane identity color")
        #expect(text.contains("\u{1B}]12;#000000\u{07}"), "cursor goes black")
        #expect(text.contains("\u{1B}]4;0;#1E1E1E;1;#B3261E;"), "palette starts at index 0")
        #expect(text.contains(";15;#202020\u{07}"), "all 16 palette entries are set")
    }

    @Test("deactivation resets palette, foreground, background, and cursor")
    func deactivationSequenceShape() {
        let text = String(decoding: PaneFocusColorScheme.deactivationSequence, as: UTF8.self)
        #expect(text == "\u{1B}]104\u{07}\u{1B}]110\u{07}\u{1B}]111\u{07}\u{1B}]112\u{07}")
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
