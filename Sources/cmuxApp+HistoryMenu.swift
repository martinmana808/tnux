import AppKit
import CmuxWorkspaces
import SwiftUI

extension cmuxApp {
    @CommandsBuilder
    var historyCommands: some Commands {
        CommandMenu(String(localized: "menu.history.title", defaultValue: "History")) {
            let historyTabManager = activeTabManager
            let recentlyFocusedSnapshot = recentlyFocusedMenuSnapshot(manager: historyTabManager)

            splitCommandButton(title: String(localized: "menu.history.focusBack", defaultValue: "Focus Back"), shortcut: menuShortcut(for: .focusHistoryBack)) {
                historyTabManager.navigateBack()
            }
            .disabled(!canNavigateFocusHistoryBack)

            splitCommandButton(title: String(localized: "menu.history.focusForward", defaultValue: "Focus Forward"), shortcut: menuShortcut(for: .focusHistoryForward)) {
                historyTabManager.navigateForward()
            }
            .disabled(!canNavigateFocusHistoryForward)

            Divider()

            recentlyFocusedMenuSection(
                manager: historyTabManager,
                snapshot: recentlyFocusedSnapshot
            )

            Divider()

            splitCommandButton(title: String(localized: "menu.file.restorePreviousAppLaunch", defaultValue: "Restore Previous Launch"), shortcut: menuShortcut(for: .reopenPreviousSession)) {
                if AppDelegate.shared?.reopenPreviousSession() != true {
                    NSSound.beep()
                }
            }

            Button(String(localized: "menu.file.restoreLayoutFromBackup", defaultValue: "Restore Layout From Backup…")) {
                _ = AppDelegate.shared?.restoreLayoutFromBackup()
            }
        }
    }

    @ViewBuilder
    private func recentlyFocusedMenuSection(
        manager: TabManager,
        snapshot: FocusHistoryMenuSnapshot
    ) -> some View {
        Button(historyMenuSectionTitle(
            title: String(localized: "menu.history.recentlyFocused", defaultValue: "Recently Focused"),
            subtitle: String(localized: "menu.history.recentlyFocused.subtitle", defaultValue: "Most recent focus targets")
        )) {}
            .disabled(true)

        if snapshot.items.isEmpty {
            Button(String(localized: "menu.history.noFocusHistory", defaultValue: "No Focus History")) {}
                .disabled(true)
        } else {
            ForEach(snapshot.items, id: \.historyIndex) { item in
                Button(FocusHistoryMenuFormatter.menuTitle(for: item)) {
                    if !manager.navigateToFocusHistoryMenuItem(item) {
                        NSSound.beep()
                    }
                }
                .disabled(!item.isNavigable)
            }
        }
    }

    @ViewBuilder
    private func recentlyClosedMenuSection(
        manager: TabManager,
        snapshot: ClosedItemHistoryMenuSnapshot
    ) -> some View {
        Button(historyMenuSectionTitle(
            title: String(localized: "menu.history.recentlyClosed", defaultValue: "Recently Closed"),
            subtitle: String(localized: "menu.history.recentlyClosed.subtitle", defaultValue: "Tabs, workspaces, and windows")
        )) {}
            .disabled(true)

        if snapshot.items.isEmpty {
            Button(String(localized: "menu.history.recentlyClosed.empty", defaultValue: "No Recently Closed Items")) {}
                .disabled(true)
        } else {
            ForEach(snapshot.items) { item in
                Button(item.menuTitle) {
                    if AppDelegate.shared?.reopenClosedHistoryItem(
                        id: item.id,
                        preferredTabManager: manager
                    ) != true {
                        NSSound.beep()
                    }
                }
            }
        }
    }

    private var canNavigateFocusHistoryBack: Bool {
        let _ = focusHistoryMenuInvalidator.revision
        let manager = activeTabManager
        return manager.canNavigateBack
    }

    private var canNavigateFocusHistoryForward: Bool {
        let _ = focusHistoryMenuInvalidator.revision
        let manager = activeTabManager
        return manager.canNavigateForward
    }

    private var recentlyClosedMenuSnapshot: ClosedItemHistoryMenuSnapshot {
        let _ = closedItemHistoryStore.revision
        return closedItemHistoryStore.menuSnapshot(maxItemCount: 10)
    }

    private func historyMenuSectionTitle(title: String, subtitle: String) -> String {
        HistoryMenuLineFormatter.titleWithSubtitle(title: title, subtitle: subtitle)
    }

    private func recentlyFocusedMenuSnapshot(manager: TabManager) -> FocusHistoryMenuSnapshot {
        let _ = focusHistoryMenuInvalidator.revision
        let back = manager.focusHistoryMenuSnapshot(direction: .back)
        let forward = manager.focusHistoryMenuSnapshot(direction: .forward)
        return FocusHistoryMenuSnapshot.recentlyFocused(
            back: back,
            forward: forward,
            maxItemCount: 30
        )
    }

}


// MARK: - Arrange menu (grid layouts)

extension cmuxApp {
    @CommandsBuilder
    var arrangeCommands: some Commands {
        CommandMenu(String(localized: "menu.arrange.title", defaultValue: "Arrange")) {
            let manager = activeTabManager
            ForEach(1...4, id: \.self) { columns in
                Button(String(localized: "command.arrangePanesColumns.title", defaultValue: "Arrange Panes in \(columns) Columns")) {
                    if !manager.arrangePanes(columns: columns) { NSSound.beep() }
                }
            }
            Divider()
            ForEach(1...4, id: \.self) { rows in
                Button(String(localized: "command.arrangePanesRows.title", defaultValue: "Arrange Panes in \(rows) Rows")) {
                    if !manager.arrangePanes(rows: rows) { NSSound.beep() }
                }
            }
            Divider()
            equalizeSplitsCommandButton()
        }
    }
}

// MARK: - Panes menu (every pane, every workspace, with agent status)

/// One row of the Panes menu: a pane across any window/workspace plus the
/// agent status cmux knows about it.
struct PaneMenuEntry: Identifiable, Equatable {
    enum Status: Equatable {
        case needsInput
        case running
        case idle
        case none

        var glyph: String {
            switch self {
            case .needsInput: return "🔔"
            case .running: return "⚡"
            case .idle: return "💤"
            case .none: return "·"
            }
        }
    }

    let id: UUID
    let workspaceId: UUID
    let workspaceTitle: String
    let title: String
    let status: Status
    let statusText: String?

    var menuTitle: String {
        var line = "\(status.glyph) \(title)"
        if let statusText, !statusText.isEmpty { line += "  — \(statusText)" }
        return line
    }

    /// Classifies a pane from the sidebar status values its agent hooks set.
    static func status(from statusValues: [String], hasAgent: Bool) -> Status {
        let needsInput = FeedCoordinator.needsInputStatusValue.lowercased()
        for value in statusValues {
            let lowered = value.lowercased()
            if lowered == needsInput || lowered.contains("needs input") || lowered.contains("waiting") {
                return .needsInput
            }
        }
        if statusValues.contains(where: { $0.lowercased().contains("running") }) {
            return .running
        }
        return hasAgent ? .idle : .none
    }
}

extension cmuxApp {
    @MainActor
    private func paneMenuEntries() -> [PaneMenuEntry] {
        guard let delegate = AppDelegate.shared else { return [] }
        var entries: [PaneMenuEntry] = []
        for context in delegate.mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                for panelId in workspace.orderedPanelIds {
                    guard let panel = workspace.panels[panelId] else { continue }
                    let runtime = workspace.agentRuntimeState(forPanelId: panelId)
                    let values = runtime.map { $0.statusEntries.values.map(\.value) } ?? []
                    let hasAgent = runtime.map { !$0.agentPIDs.isEmpty || !$0.agentPIDKeys.isEmpty } ?? false
                    entries.append(PaneMenuEntry(
                        id: panelId,
                        workspaceId: workspace.id,
                        workspaceTitle: workspace.title,
                        title: workspace.displayTitleForMenus(panelId: panelId, fallback: panel.displayTitle),
                        status: PaneMenuEntry.status(from: values, hasAgent: hasAgent),
                        statusText: values.first
                    ))
                }
            }
        }
        return entries
    }

    @MainActor
    private func focusPaneMenuEntry(_ entry: PaneMenuEntry) {
        guard let delegate = AppDelegate.shared else { return }
        for context in delegate.mainWindowContexts.values {
            guard let workspace = context.tabManager.tabs.first(where: { $0.id == entry.workspaceId }) else { continue }
            if let window = delegate.mainWindow(for: context.windowId) {
                window.makeKeyAndOrderFront(nil)
            }
            context.tabManager.selectTab(workspace)
            workspace.focusPanel(entry.id)
            return
        }
        NSSound.beep()
    }

    @CommandsBuilder
    var panesCommands: some Commands {
        CommandMenu(String(localized: "menu.panes.title", defaultValue: "Panes")) {
            let entries = paneMenuEntries()
            let needsInput = entries.filter { $0.status == .needsInput }
            let running = entries.filter { $0.status == .running }
            if entries.isEmpty {
                Button(String(localized: "menu.panes.empty", defaultValue: "No Panes")) {}.disabled(true)
            }
            if !needsInput.isEmpty {
                Button(String(localized: "menu.panes.needsInput", defaultValue: "Needs Input")) {}.disabled(true)
                ForEach(needsInput) { entry in
                    Button("    " + entry.menuTitle) { focusPaneMenuEntry(entry) }
                }
                Divider()
            }
            if !running.isEmpty {
                Button(String(localized: "menu.panes.running", defaultValue: "Running")) {}.disabled(true)
                ForEach(running) { entry in
                    Button("    " + entry.menuTitle) { focusPaneMenuEntry(entry) }
                }
                Divider()
            }
            let byWorkspace = Dictionary(grouping: entries, by: \.workspaceId)
            ForEach(Array(byWorkspace.keys).sorted { a, b in
                (entries.firstIndex { $0.workspaceId == a } ?? 0) < (entries.firstIndex { $0.workspaceId == b } ?? 0)
            }, id: \.self) { workspaceId in
                let group = byWorkspace[workspaceId] ?? []
                Menu("\(group.first?.workspaceTitle ?? "") (\(group.count))") {
                    ForEach(group) { entry in
                        Button(entry.menuTitle) { focusPaneMenuEntry(entry) }
                    }
                }
            }
        }
    }
}
