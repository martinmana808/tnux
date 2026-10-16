import AppKit
import Combine
import Foundation
import SwiftUI

/// One pane row in the sidebar: an immutable snapshot (CLAUDE.md snapshot
/// boundary rule), never a live store reference.
struct SidebarPaneRow: Identifiable, Equatable {
    /// The panel id.
    let id: UUID
    let workspaceId: UUID
    let workspaceTitle: String
    /// `folder — title`, as the tab chip shows it.
    let title: String
    let color: Color
    let status: PaneMenuEntry.Status
    let lastActionAt: Date?
    let isFocused: Bool
    /// Position in the workspace's on-screen order.
    let layoutIndex: Int
}

/// Everything the sidebar's pane rows need, rebuilt as a value whenever a
/// pane's title, status, focus or age changes, never per keystroke.
struct SidebarPanesSnapshot: Equatable {
    var needsInput: [SidebarPaneRow] = []
    var running: [SidebarPaneRow] = []
    var rowsByWorkspace: [UUID: [SidebarPaneRow]] = [:]
    /// The focused pane of each workspace that has one (Arc-style peek).
    var focusedRowByWorkspace: [UUID: SidebarPaneRow] = [:]
    var allRows: [SidebarPaneRow] = []
    /// Workspaces in sidebar order (for Expand All).
    var workspaceIds: [UUID] = []
    /// "Now" for the gauges, rounded to the minute so rebuilds within a
    /// minute compare equal and do not re-render the rows.
    var builtAt: Date = .distantPast

    static let empty = SidebarPanesSnapshot()

    @MainActor
    static func build(workspaces: [Workspace], selectedWorkspaceId: UUID?, now: Date = Date()) -> SidebarPanesSnapshot {
        var snapshot = SidebarPanesSnapshot()
        snapshot.workspaceIds = workspaces.map(\.id)
        snapshot.builtAt = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        for workspace in workspaces {
            let focusedPanelId = workspace.focusedPanelId
            var rows: [SidebarPaneRow] = []
            for (index, panelId) in workspace.orderedPanelIds.enumerated() {
                guard let panel = workspace.panels[panelId] else { continue }
                let runtime = workspace.agentRuntimeState(forPanelId: panelId)
                let values = runtime.map { $0.statusEntries.values.map(\.value) } ?? []
                let hasAgent = runtime.map { !$0.agentPIDs.isEmpty || !$0.agentPIDKeys.isEmpty } ?? false
                let row = SidebarPaneRow(
                    id: panelId,
                    workspaceId: workspace.id,
                    workspaceTitle: workspace.title,
                    title: workspace.paneListTitle(panelId: panelId, fallback: panel.displayTitle),
                    color: Color(nsColor: workspace.paneIdentityColor(forPanelId: panelId)),
                    status: PaneMenuEntry.status(from: values, hasAgent: hasAgent),
                    lastActionAt: workspace.panelLastFocusedAt[panelId],
                    isFocused: panelId == focusedPanelId && workspace.id == selectedWorkspaceId,
                    layoutIndex: index
                )
                rows.append(row)
                if panelId == focusedPanelId {
                    snapshot.focusedRowByWorkspace[workspace.id] = row
                }
            }
            snapshot.rowsByWorkspace[workspace.id] = rows
            snapshot.allRows.append(contentsOf: rows)
        }
        snapshot.needsInput = snapshot.allRows.filter { $0.status == .needsInput }
        snapshot.running = snapshot.allRows.filter { $0.status == .running }
        return snapshot
    }

    /// Rows for a workspace in the chosen order.
    func rows(for workspaceId: UUID, sort: SidebarPanesPreferences.Sort) -> [SidebarPaneRow] {
        Self.sorted(rowsByWorkspace[workspaceId] ?? [], by: sort)
    }

    func allRows(sort: SidebarPanesPreferences.Sort) -> [SidebarPaneRow] {
        Self.sorted(allRows, by: sort)
    }

    static func sorted(_ rows: [SidebarPaneRow], by sort: SidebarPanesPreferences.Sort) -> [SidebarPaneRow] {
        switch sort {
        case .layout:
            return rows
        case .lastPrompted:
            // Unknown ages sink to the bottom; ties keep layout order.
            return rows.enumerated().sorted { lhs, rhs in
                switch (lhs.element.lastActionAt, rhs.element.lastActionAt) {
                case let (l?, r?) where l != r: return l > r
                case (nil, .some): return false
                case (.some, nil): return true
                default: return lhs.offset < rhs.offset
                }
            }.map(\.element)
        }
    }
}

/// Persisted sidebar choices: which workspaces are expanded, the flat
/// "view all" mode and the row sort. Shared by the sidebar, the Panes menu
/// and the command palette.
@MainActor
final class SidebarPanesPreferences: ObservableObject {
    enum Sort: String, CaseIterable {
        case layout
        case lastPrompted
    }

    static let shared = SidebarPanesPreferences()
    static let expandedKey = "tnux.sidebar.expandedWorkspaceIds"
    static let viewAllKey = "tnux.sidebar.viewAllPanes"
    static let sortKey = "tnux.sidebar.paneSort"

    private let defaults: UserDefaults

    @Published var expandedWorkspaceIds: Set<UUID> {
        didSet { defaults.set(expandedWorkspaceIds.map(\.uuidString).sorted(), forKey: Self.expandedKey) }
    }
    @Published var viewAll: Bool {
        didSet { defaults.set(viewAll, forKey: Self.viewAllKey) }
    }
    @Published var sort: Sort {
        didSet { defaults.set(sort.rawValue, forKey: Self.sortKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        expandedWorkspaceIds = Set((defaults.stringArray(forKey: Self.expandedKey) ?? []).compactMap(UUID.init(uuidString:)))
        viewAll = defaults.bool(forKey: Self.viewAllKey)
        sort = defaults.string(forKey: Self.sortKey).flatMap(Sort.init(rawValue:)) ?? .layout
    }

    func isExpanded(_ workspaceId: UUID) -> Bool {
        expandedWorkspaceIds.contains(workspaceId)
    }

    func toggle(_ workspaceId: UUID) {
        if expandedWorkspaceIds.contains(workspaceId) {
            expandedWorkspaceIds.remove(workspaceId)
        } else {
            expandedWorkspaceIds.insert(workspaceId)
        }
    }

    func allExpanded(_ workspaceIds: [UUID]) -> Bool {
        !workspaceIds.isEmpty && workspaceIds.allSatisfy { expandedWorkspaceIds.contains($0) }
    }

    func expandAll(_ workspaceIds: [UUID]) {
        expandedWorkspaceIds.formUnion(workspaceIds)
    }

    func collapseAll() {
        expandedWorkspaceIds = []
    }

    /// Expand All when any workspace is collapsed, Collapse All otherwise.
    func toggleAll(_ workspaceIds: [UUID]) {
        if allExpanded(workspaceIds) { collapseAll() } else { expandAll(workspaceIds) }
    }
}

/// Owns the sidebar's pane snapshot for one window. Recomputes, coalesced,
/// when any workspace or the tab manager publishes a change, and once a
/// minute so the age gauges step at 05:00.
@MainActor
final class SidebarPanesModel: ObservableObject {
    @Published private(set) var snapshot: SidebarPanesSnapshot = .empty

    private weak var tabManager: TabManager?
    private var cancellables: Set<AnyCancellable> = []
    private var workspaceCancellables: [UUID: AnyCancellable] = [:]
    private var refreshPending = false
    private var tick: AnyCancellable?

    func attach(_ tabManager: TabManager) {
        guard self.tabManager !== tabManager else { return }
        self.tabManager = tabManager
        cancellables.removeAll()
        tabManager.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .tabManagerFocusHistoryRevisionDidChange)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .ghosttyDidSetTitle)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        tick = Timer.publish(every: 60, tolerance: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshNow() }
        refreshNow()
    }

    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshPending = false
            self?.refreshNow()
        }
    }

    func refreshNow() {
        guard let tabManager else { return }
        observeWorkspaces(tabManager.tabs)
        let next = SidebarPanesSnapshot.build(workspaces: tabManager.tabs, selectedWorkspaceId: tabManager.selectedTabId)
        if next != snapshot {
            snapshot = next
        }
    }

    private func observeWorkspaces(_ workspaces: [Workspace]) {
        let ids = Set(workspaces.map(\.id))
        for id in workspaceCancellables.keys where !ids.contains(id) {
            workspaceCancellables[id] = nil
        }
        for workspace in workspaces where workspaceCancellables[workspace.id] == nil {
            workspaceCancellables[workspace.id] = workspace.objectWillChange
                .sink { [weak self] _ in self?.scheduleRefresh() }
        }
    }
}
