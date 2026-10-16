import AppKit
import CMUXAgentLaunch
import Foundation

/// Keeps every pane's last-action stamp in step with its Claude transcript:
/// once shortly after launch (when restore has bound panes to sessions) and
/// then once a minute. The first pass of this build replaces stamps written
/// before actions were tracked, so panes untouched for weeks stop looking
/// fresh.
extension AppDelegate {
    static let paneLastActionMigrationKey = "tnux.lastActionStampsFromTranscript.v1"
    static let paneLastActionRefreshInterval: TimeInterval = 60

    func startPaneLastActionRefresh() {
        guard paneLastActionRefreshTimer == nil else { return }
        let timer = Timer(timeInterval: Self.paneLastActionRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPaneLastActionsFromTranscripts() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        paneLastActionRefreshTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.refreshPaneLastActionsFromTranscripts()
        }
    }

    func refreshPaneLastActionsFromTranscripts(defaults: UserDefaults = .standard) {
        let workspaces = mainWindowContexts.values.flatMap { $0.tabManager.tabs }
        guard workspaces.contains(where: { !$0.orderedPanelIds.isEmpty }) else { return }
        let replacing = !defaults.bool(forKey: Self.paneLastActionMigrationKey)
        for workspace in workspaces {
            workspace.refreshLastActionsFromTranscripts(replacing: replacing)
        }
        if replacing {
            defaults.set(true, forKey: Self.paneLastActionMigrationKey)
        }
    }

    /// Agent hook side effects for the age gauge: a submitted prompt is an
    /// action in that pane, and the reported transcript path becomes the
    /// pane's backfill source.
    func notePaneActivityFromHook(_ event: WorkstreamEvent) {
        guard let raw = event.surfaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              let panelId = UUID(uuidString: raw),
              let located = locateSurface(surfaceId: panelId),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId })
        else { return }
        if let transcriptPath = event.transcriptPath {
            workspace.noteTranscriptPath(transcriptPath, panelId: panelId)
        }
        if event.hookEventName == .userPromptSubmit {
            workspace.notePaneAction(panelId: panelId, at: event.receivedAt)
        }
    }
}
