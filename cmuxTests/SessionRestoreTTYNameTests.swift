import Foundation
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for session-restore tty attribution.
///
/// A local pty does not survive an app relaunch, so a tty name persisted in a
/// session snapshot describes a device the restored pane no longer owns. If the
/// stale name is written back onto the new pane, every consumer that maps a tty
/// to a pane (claude-hook routing, `debug.terminals`, `system.top`, the port
/// scanner) attributes another pane's processes and agent sessions to it, and the
/// next autosave persists that cross-wiring.
@Suite("Session restore tty names")
struct SessionRestoreTTYNameTests {
    private static func workspaceSnapshot(
        panelId: UUID,
        ttyName: String,
        terminal: SessionTerminalPanelSnapshot,
        remote: SessionRemoteWorkspaceSnapshot? = nil
    ) -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            workspaceId: UUID(),
            processTitle: "Shell",
            customTitle: nil,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            groupId: nil,
            isManuallyUnread: false,
            hasUnreadIndicator: false,
            notifications: nil,
            terminalScrollBarHidden: nil,
            currentDirectory: "/tmp",
            focusedPanelId: panelId,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [panelId],
                selectedPanelId: panelId
            )),
            panels: [
                SessionPanelSnapshot(
                    id: panelId,
                    type: .terminal,
                    title: "Shell",
                    customTitle: nil,
                    directory: "/tmp",
                    isPinned: false,
                    isManuallyUnread: false,
                    hasUnreadIndicator: false,
                    restoredUnreadContributesToWorkspace: nil,
                    notifications: nil,
                    gitBranch: nil,
                    listeningPorts: [],
                    ttyName: ttyName,
                    terminal: terminal,
                    browser: nil,
                    markdown: nil,
                    filePreview: nil,
                    rightSidebarTool: nil,
                    agentSession: nil,
                    project: nil
                ),
            ],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: remote
        )
    }

    @MainActor
    @Test("local terminal restore drops the persisted tty name")
    func localTerminalRestoreDropsPersistedTTYName() throws {
        let panelId = UUID()
        let snapshot = Self.workspaceSnapshot(
            panelId: panelId,
            ttyName: "ttys099",
            terminal: SessionTerminalPanelSnapshot(workingDirectory: "/tmp")
        )

        let restored = Workspace()
        let restoredIds = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restoredIds[panelId])

        #expect(
            restored.surfaceTTYNames[restoredPanelId] == nil,
            "A relaunched local pane must not inherit the pre-relaunch tty name"
        )
    }

    @MainActor
    @Test("remote terminal restore keeps the persisted tty name")
    func remoteTerminalRestoreKeepsPersistedTTYName() throws {
        let panelId = UUID()
        let snapshot = Self.workspaceSnapshot(
            panelId: panelId,
            ttyName: "pts/7",
            terminal: SessionTerminalPanelSnapshot(isRemoteTerminal: true),
            remote: SessionRemoteWorkspaceSnapshot(
                transport: .ssh,
                destination: "dev@example.com",
                port: 22,
                identityFile: nil,
                sshOptions: [],
                preserveAfterTerminalExit: nil,
                skipDaemonBootstrap: nil
            )
        )

        let restored = Workspace()
        let restoredIds = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restoredIds[panelId])

        #expect(restored.surfaceTTYNames[restoredPanelId] == "pts/7")
    }

    @MainActor
    @Test("live pty tty replaces a stale cached tty name")
    func livePTYTTYNameReplacesStaleCachedName() throws {
        let workspace = Workspace(workingDirectory: "/tmp")
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.surfaceTTYNames[panel.id] = "ttys001"

        let resolved = workspace.liveSurfaceTTYName(
            panelId: panel.id,
            liveTTYNameProvider: { _ in "/dev/ttys042" }
        )

        #expect(resolved == "ttys042")
        #expect(workspace.surfaceTTYNames[panel.id] == "ttys042")
    }

    @MainActor
    @Test("cached tty name is used when the live pty is unavailable")
    func cachedTTYNameIsUsedWhenLivePTYIsUnavailable() throws {
        let workspace = Workspace(workingDirectory: "/tmp")
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.surfaceTTYNames[panel.id] = "ttys007"

        let resolved = workspace.liveSurfaceTTYName(
            panelId: panel.id,
            liveTTYNameProvider: { _ in nil }
        )

        #expect(resolved == "ttys007")
    }
}
