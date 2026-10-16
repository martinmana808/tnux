import AppKit
import Foundation

/// One pane in the action-ordered history: where the user last sent a
/// message or ran a command, most recent first.
struct PaneActionHistoryEntry: Identifiable, Equatable {
    /// The panel id.
    let id: UUID
    let workspaceId: UUID
    let workspaceTitle: String
    /// `folder — title`, as the tab chip shows it.
    let title: String
    let lastActionAt: Date
}

/// Focus Back / Focus Forward and the Recent Actions lists walk this history
/// instead of the focus history: focusing a pane by accident never enters
/// it, only acting in it does (see `Workspace.notePaneAction`).
enum PaneActionHistory {
    enum Direction {
        case back
        case forward
    }

    @MainActor
    static func entries(workspaces: [Workspace]) -> [PaneActionHistoryEntry] {
        var entries: [PaneActionHistoryEntry] = []
        for workspace in workspaces {
            for panelId in workspace.orderedPanelIds {
                guard let panel = workspace.panels[panelId], let lastActionAt = workspace.panelLastFocusedAt[panelId] else { continue }
                entries.append(PaneActionHistoryEntry(
                    id: panelId,
                    workspaceId: workspace.id,
                    workspaceTitle: workspace.title,
                    title: workspace.paneListTitle(panelId: panelId, fallback: panel.displayTitle),
                    lastActionAt: lastActionAt
                ))
            }
        }
        return entries.sorted { lhs, rhs in
            if lhs.lastActionAt != rhs.lastActionAt { return lhs.lastActionAt > rhs.lastActionAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Index of the pane to focus next. Back from a pane in the list goes to
    /// the next older one; back from a pane that is not in the list (or
    /// from nowhere) goes to the most recent action. Forward goes to the
    /// next newer one and stops at the top.
    static func targetIndex(
        entries: [PaneActionHistoryEntry],
        focusedPanelId: UUID?,
        direction: Direction
    ) -> Int? {
        guard !entries.isEmpty else { return nil }
        let current = focusedPanelId.flatMap { id in entries.firstIndex { $0.id == id } }
        switch direction {
        case .back:
            guard let current else { return 0 }
            return current + 1 < entries.count ? current + 1 : nil
        case .forward:
            guard let current, current > 0 else { return nil }
            return current - 1
        }
    }
}

extension Workspace {
    /// Menu/list title for a pane: the project folder, then the pane title.
    func paneListTitle(panelId: UUID, fallback: String) -> String {
        let title = displayTitleForMenus(panelId: panelId, fallback: fallback)
        if let folder = projectSegment(forPanelId: panelId), !title.hasPrefix(folder) {
            return "\(folder) — \(title)"
        }
        return title
    }

    /// Focuses a panel and, when the workspace is zoomed on another pane,
    /// moves the zoom to the target so the focused pane is the visible one.
    func focusPanelFollowingZoom(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        guard layoutMode != .canvas, let targetPaneId = paneId(forPanelId: panelId) else {
            focusPanel(panelId)
            return
        }
        let wasZoomed = bonsplitController.isSplitZoomed
        let zoomMoves = wasZoomed && bonsplitController.zoomedPaneId != targetPaneId
        if zoomMoves {
            _ = bonsplitController.clearPaneZoom()
        }
        focusPanel(panelId)
        if zoomMoves {
            _ = bonsplitController.togglePaneZoom(inPane: targetPaneId)
        }
    }
}

extension TabManager {
    /// Panes of this window ordered by the user's last action.
    var paneActionHistoryEntries: [PaneActionHistoryEntry] {
        PaneActionHistory.entries(workspaces: tabs)
    }

    var canNavigateActionHistoryBack: Bool {
        PaneActionHistory.targetIndex(
            entries: paneActionHistoryEntries,
            focusedPanelId: selectedWorkspace?.focusedPanelId,
            direction: .back
        ) != nil
    }

    var canNavigateActionHistoryForward: Bool {
        PaneActionHistory.targetIndex(
            entries: paneActionHistoryEntries,
            focusedPanelId: selectedWorkspace?.focusedPanelId,
            direction: .forward
        ) != nil
    }

    /// Shared path for Cmd+[ / Cmd+], the History menu and the palette.
    @discardableResult
    func navigateActionHistory(_ direction: PaneActionHistory.Direction) -> Bool {
        let entries = paneActionHistoryEntries
        guard let index = PaneActionHistory.targetIndex(
            entries: entries,
            focusedPanelId: selectedWorkspace?.focusedPanelId,
            direction: direction
        ) else { return false }
        return focusPane(panelId: entries[index].id, workspaceId: entries[index].workspaceId)
    }

    /// Brings a pane of this window to the front: selects its workspace and
    /// focuses it, zoom following.
    @discardableResult
    func focusPane(panelId: UUID, workspaceId: UUID) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }), workspace.panels[panelId] != nil else { return false }
        if selectedTabId != workspace.id {
            selectTab(workspace)
        }
        workspace.focusPanelFollowingZoom(panelId)
        return true
    }
}

extension AppDelegate {
    /// Brings a pane to the front wherever it lives: its window, then its
    /// workspace, then the pane. One path for the Panes menu, the sidebar
    /// rows, the palette and the action history.
    @discardableResult
    func focusPane(panelId: UUID, workspaceId: UUID) -> Bool {
        for context in mainWindowContexts.values {
            guard let workspace = context.tabManager.tabs.first(where: { $0.id == workspaceId }),
                  workspace.panels[panelId] != nil else { continue }
            if let window = mainWindow(for: context.windowId) {
                window.makeKeyAndOrderFront(nil)
            }
            return context.tabManager.focusPane(panelId: panelId, workspaceId: workspaceId)
        }
        return false
    }
}

/// Localized rows for the History menu and the palette.
enum PaneActionHistoryFormatter {
    static func title(for entry: PaneActionHistoryEntry) -> String {
        let fallbackWorkspaceTitle = String(localized: "menu.history.untitledWorkspace", defaultValue: "Untitled Workspace")
        let workspaceTitle = entry.workspaceTitle.isEmpty ? fallbackWorkspaceTitle : entry.workspaceTitle
        guard !entry.title.isEmpty, entry.title != workspaceTitle else { return workspaceTitle }
        return String.localizedStringWithFormat(
            String(localized: "menu.history.focusedItemTitleFormat", defaultValue: "%1$@ - %2$@"),
            entry.title,
            workspaceTitle
        )
    }

    static func subtitle(for entry: PaneActionHistoryEntry, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return String.localizedStringWithFormat(
            String(localized: "historyPane.lastActionFormat", defaultValue: "Last action %@"),
            formatter.localizedString(for: entry.lastActionAt, relativeTo: now)
        )
    }

    static func menuTitle(for entry: PaneActionHistoryEntry) -> String {
        HistoryMenuLineFormatter.titleWithSubtitle(title: title(for: entry), subtitle: subtitle(for: entry))
    }
}
