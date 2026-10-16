import AppKit
import Bonsplit
import CmuxSettings
import CmuxCore
import Darwin
import CmuxPanes
import Foundation
import CmuxSidebar

extension Workspace {
    private static let structuredAgentHookStatusKeys = AgentHibernationLifecycleStatusKeys.allowedStatusKeys
    private static let managedSubagentEnvironmentKey = "CMUX_AGENT_MANAGED_SUBAGENT"
    private static let truthyStartupEnvironmentValues: Set<String> = ["1", "true", "yes", "on", "enabled"]

    var agentPIDs: [String: pid_t] {
        get { sidebarAgentRuntimeObservation.agentPIDs }
        set { sidebarAgentRuntimeObservation.setAgentPIDs(newValue) }
    }

    var agentPIDProcessIdentitiesByKey: [String: AgentPIDProcessIdentity] {
        get { sidebarAgentRuntimeObservation.agentPIDProcessIdentitiesByKey }
        set { sidebarAgentRuntimeObservation.setAgentPIDProcessIdentitiesByKey(newValue) }
    }

    var agentPIDPanelIdsByKey: [String: UUID] {
        get { sidebarAgentRuntimeObservation.agentPIDPanelIdsByKey }
        set { sidebarAgentRuntimeObservation.setAgentPIDPanelIdsByKey(newValue) }
    }

    var agentPIDKeysByPanelId: [UUID: Set<String>] {
        get { sidebarAgentRuntimeObservation.agentPIDKeysByPanelId }
        set { sidebarAgentRuntimeObservation.setAgentPIDKeysByPanelId(newValue) }
    }

    var agentLifecycleStatesByPanelId: [UUID: [String: AgentHibernationLifecycleState]] {
        get { sidebarAgentRuntimeObservation.agentLifecycleStatesByPanelId }
        set { sidebarAgentRuntimeObservation.setAgentLifecycleStatesByPanelId(newValue) }
    }

    func agentRuntimeState(forPanelId panelId: UUID) -> DetachedAgentRuntimeState? {
        let pidKeys = agentPIDKeysByPanelId[panelId] ?? []

        var agentPIDsForPanel: [String: pid_t] = [:]
        var statusEntriesForPanel: [String: SidebarStatusEntry] = [:]
        for key in pidKeys {
            if let pid = agentPIDs[key] {
                agentPIDsForPanel[key] = pid
            }
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            if let statusEntry = statusEntries[statusKey] {
                statusEntriesForPanel[statusKey] = statusEntry
            }
        }
        guard !statusEntriesForPanel.isEmpty || !agentPIDsForPanel.isEmpty || !pidKeys.isEmpty else { return nil }
        return DetachedAgentRuntimeState(
            panelId: panelId,
            statusEntries: statusEntriesForPanel,
            agentPIDs: agentPIDsForPanel,
            agentPIDKeys: pidKeys
        )
    }

    private func agentStatusKey(forAgentPIDKey key: String) -> String {
        if statusEntries[key] != nil {
            return key
        }
        guard let dotIndex = key.firstIndex(of: ".") else {
            return key
        }
        return String(key[..<dotIndex])
    }

    private func hasAgentRuntime(forStatusKey statusKey: String) -> Bool {
        for key in agentPIDs.keys where agentStatusKey(forAgentPIDKey: key) == statusKey {
            return true
        }
        for key in agentPIDPanelIdsByKey.keys where agentStatusKey(forAgentPIDKey: key) == statusKey {
            return true
        }
        return false
    }

    private func removeAgentPIDOwnership(key: String) {
        if let previousPanelId = agentPIDPanelIdsByKey[key] {
            agentPIDKeysByPanelId[previousPanelId]?.remove(key)
            if agentPIDKeysByPanelId[previousPanelId]?.isEmpty == true {
                agentPIDKeysByPanelId.removeValue(forKey: previousPanelId)
            }
            agentPIDPanelIdsByKey.removeValue(forKey: key)
        }
    }

    private func recordAgentPIDOwnership(key: String, panelId: UUID) {
        if let previousPanelId = agentPIDPanelIdsByKey[key], previousPanelId != panelId {
            removeAgentPIDOwnership(key: key)
        }
        if isStructuredAgentHookPIDKey(key) {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            let stalePanelKeys = agentPIDKeysByPanelId[panelId]?.filter {
                $0 != key &&
                isStructuredAgentHookPIDKey($0) &&
                agentStatusKey(forAgentPIDKey: $0) != statusKey
            } ?? []
            for staleKey in stalePanelKeys {
                _ = clearAgentPID(key: staleKey, panelId: panelId, clearStatus: true, refreshPorts: false)
            }
        }
        agentPIDPanelIdsByKey[key] = panelId
        agentPIDKeysByPanelId[panelId, default: []].insert(key)
    }

    @discardableResult
    private func clearOtherStructuredAgentRuntimes(onPanel panelId: UUID, keeping retainedKey: String) -> Bool {
        guard isStructuredAgentHookPIDKey(retainedKey) else { return false }
        let staleKeys = agentPIDKeysByPanelId[panelId] ?? []
        var didChange = false
        for staleKey in staleKeys where staleKey != retainedKey && isStructuredAgentHookPIDKey(staleKey) {
            if clearAgentPID(key: staleKey, panelId: panelId, clearStatus: true, refreshPorts: false) {
                didChange = true
            }
        }
        return didChange
    }

    @discardableResult
    func recordAgentPID(key: String, pid: pid_t, panelId: UUID?, refreshPorts: Bool = true) -> Bool {
        var didClearOtherStructuredAgentRuntime = false
        if let panelId {
            didClearOtherStructuredAgentRuntime = clearOtherStructuredAgentRuntimes(onPanel: panelId, keeping: key)
        }
        agentPIDs[key] = pid
        agentPIDProcessIdentitiesByKey[key] = Self.agentPIDProcessIdentity(pid: pid)
        if let panelId {
            recordAgentPIDOwnership(key: key, panelId: panelId)
        } else {
            removeAgentPIDOwnership(key: key)
        }
        if refreshPorts {
            refreshTrackedAgentPorts()
        }
        return didClearOtherStructuredAgentRuntime
    }

    @discardableResult
    func clearStaleAgentPIDs(refreshPorts: Bool = true) -> Bool {
        var didChange = false
        for (key, pid) in agentPIDs where !isRecordedAgentPIDLive(key: key, pid: pid) {
            if clearAgentPID(key: key, clearStatus: true, refreshPorts: false) {
                didChange = true
            }
        }
        if didChange, refreshPorts {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    @discardableResult
    func clearStaleAgentPIDs(panelId: UUID, refreshPorts: Bool = true) -> Bool {
        let keys = agentPIDKeysByPanelId[panelId] ?? []
        var didChange = false
        for key in keys {
            guard let pid = agentPIDs[key] else {
                if clearAgentPID(key: key, panelId: panelId, clearStatus: true, refreshPorts: false) {
                    didChange = true
                }
                continue
            }
            if !isRecordedAgentPIDLive(key: key, pid: pid),
               clearAgentPID(key: key, panelId: panelId, clearStatus: true, refreshPorts: false) {
                didChange = true
            }
        }
        if didChange, refreshPorts {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    func clearAllAgentPIDs(refreshPorts: Bool = true) {
        let hadAgentPIDs = !agentPIDs.isEmpty
        agentPIDs.removeAll()
        agentPIDProcessIdentitiesByKey.removeAll()
        agentPIDPanelIdsByKey.removeAll()
        agentPIDKeysByPanelId.removeAll()
        if hadAgentPIDs, refreshPorts {
            refreshTrackedAgentPorts()
        }
    }

    private func isRecordedAgentPIDLive(key: String, pid: pid_t) -> Bool {
        guard pid > 0,
              let recordedIdentity = agentPIDProcessIdentitiesByKey[key],
              let currentIdentity = Self.agentPIDProcessIdentity(pid: pid) else {
            return false
        }
        return currentIdentity == recordedIdentity
    }

    private static func agentPIDProcessIdentity(pid: pid_t) -> AgentPIDProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        return AgentPIDProcessIdentity(
            pid: pid,
            startSeconds: Int64(info.pbi_start_tvsec),
            startMicroseconds: Int64(info.pbi_start_tvusec)
        )
    }

    func suppressesRawTerminalNotification(panelId: UUID?) -> Bool {
        guard let panelId else {
            return false
        }

        if AgentIntegrationSettingsStore(defaults: .standard).suppressesSubagentNotifications,
           terminalPanelHasManagedSubagentStartupEnvironment(panelId: panelId) {
            return true
        }

        let panelKeys = agentPIDKeysByPanelId[panelId] ?? []
        return panelKeys.contains { isStructuredAgentHookPIDKey($0) }
    }

    private func terminalPanelHasManagedSubagentStartupEnvironment(panelId: UUID) -> Bool {
        guard let rawValue = terminalPanel(for: panelId)?
            .surface
            .startupEnvironmentValue(Self.managedSubagentEnvironmentKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return Self.truthyStartupEnvironmentValues.contains(rawValue)
    }

    func sidebarStatusEntriesVisibleForDisplay() -> [SidebarStatusEntry] {
        let visibleStructuredStatusKeys = visibleStructuredAgentStatusKeysByPanel()
        return statusEntries.values.filter { entry in
            shouldDisplaySidebarStatusEntry(entry, visibleStructuredStatusKeys: visibleStructuredStatusKeys)
        }
    }

    private func shouldDisplaySidebarStatusEntry(
        _ entry: SidebarStatusEntry,
        visibleStructuredStatusKeys: Set<String>
    ) -> Bool {
        guard Self.structuredAgentHookStatusKeys.contains(entry.key) else {
            return true
        }
        return visibleStructuredStatusKeys.contains(entry.key)
    }

    private func visibleStructuredAgentStatusKeysByPanel() -> Set<String> {
        var statusKeysByPanelId: [UUID: Set<String>] = [:]
        for (key, panelId) in agentPIDPanelIdsByKey
        where panels[panelId] != nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard Self.structuredAgentHookStatusKeys.contains(statusKey),
                  statusEntries[statusKey] != nil else {
                continue
            }
            statusKeysByPanelId[panelId, default: []].insert(statusKey)
        }
        var visibleStatusKeys = Set<String>()
        for statusKeys in statusKeysByPanelId.values {
            let winningEntry = statusKeys.compactMap { statusEntries[$0] }.max {
                isSidebarStatusEntryLessCurrent($0, than: $1)
            }
            if let winningEntry {
                visibleStatusKeys.insert(winningEntry.key)
            }
        }

        for key in agentPIDs.keys where agentPIDPanelIdsByKey[key] == nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard Self.structuredAgentHookStatusKeys.contains(statusKey),
                  statusEntries[statusKey] != nil else {
                continue
            }
            visibleStatusKeys.insert(statusKey)
        }

        return visibleStatusKeys
    }

    private func isSidebarStatusEntryLessCurrent(
        _ lhs: SidebarStatusEntry,
        than rhs: SidebarStatusEntry
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        return lhs.key > rhs.key
    }

    private func isStructuredAgentHookPIDKey(_ key: String) -> Bool {
        Self.structuredAgentHookStatusKeys.contains(agentStatusKey(forAgentPIDKey: key))
    }

    @discardableResult
    func clearAgentPID(
        key: String,
        panelId: UUID? = nil,
        clearStatus: Bool = false,
        refreshPorts: Bool = true
    ) -> Bool {
        let ownedPanelId = agentPIDPanelIdsByKey[key]
        if let panelId, let ownedPanelId, ownedPanelId != panelId {
            return false
        }
        let statusKeyToClear = clearStatus ? agentStatusKey(forAgentPIDKey: key) : nil

        var didChange = false
        if agentPIDs.removeValue(forKey: key) != nil {
            didChange = true
        }
        if agentPIDProcessIdentitiesByKey.removeValue(forKey: key) != nil {
            didChange = true
        }
        if ownedPanelId != nil {
            removeAgentPIDOwnership(key: key)
            didChange = true
        }
        if let lifecyclePanelId = ownedPanelId ?? panelId {
            let lifecycleStatusKey = agentStatusKey(forAgentPIDKey: key)
            if clearAgentLifecycle(key: lifecycleStatusKey, panelId: lifecyclePanelId) {
                didChange = true
            }
        }
        if let statusKeyToClear,
           !hasAgentRuntime(forStatusKey: statusKeyToClear),
           statusEntries.removeValue(forKey: statusKeyToClear) != nil {
            didChange = true
        }
        if didChange, refreshPorts {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    func refreshTrackedAgentPorts() {
        agentListeningPorts.removeAll(keepingCapacity: false)
        let remainingAgentPIDs = Set(agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
        PortScanner.shared.refreshAgentPorts(workspaceId: id, agentPIDs: remainingAgentPIDs)
        recomputeListeningPorts()
    }

    @discardableResult
    private func discardAgentRuntimeState(_ runtimeState: DetachedAgentRuntimeState?) -> Bool {
        guard let runtimeState else { return false }
        var didChange = false
        for key in runtimeState.agentPIDKeys {
            if clearAgentPID(key: key, panelId: runtimeState.panelId, clearStatus: true, refreshPorts: false) {
                didChange = true
            }
        }
        if didChange {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    func adoptDetachedAgentRuntimeState(_ runtimeState: DetachedAgentRuntimeState?) {
        guard let runtimeState else { return }
        for (statusKey, statusEntry) in runtimeState.statusEntries {
            statusEntries[statusKey] = statusEntry
        }
        var didAdoptAgentPID = false
        for (key, pid) in runtimeState.agentPIDs {
            recordAgentPID(key: key, pid: pid, panelId: runtimeState.panelId, refreshPorts: false)
            didAdoptAgentPID = true
        }
        for key in runtimeState.agentPIDKeys where runtimeState.agentPIDs[key] == nil {
            recordAgentPIDOwnership(key: key, panelId: runtimeState.panelId)
        }
        if didAdoptAgentPID {
            refreshTrackedAgentPorts()
        }
    }

    /// Discard every Workspace-owned contribution for a surface whose tab,
    /// pane, or workspace has already been accepted for closure.
    @discardableResult
    func discardClosedPanelLifecycleState(
        panelId: UUID,
        tabId: TabID? = nil,
        paneId: PaneID?,
        panel: (any Panel)?,
        origin: String,
        closePanel: Bool,
        publishSurfaceClosedEvent: Bool,
        clearSurfaceNotifications: Bool,
        requestTransferredRemoteCleanup: Bool,
        cleanupControllerSurfaceState: Bool = false
    ) -> WorkspaceRemoteConfiguration? {
        if publishSurfaceClosedEvent {
            publishCmuxSurfaceClosed(panelId, paneId: paneId, panel: panel, origin: origin)
        }

        let closedAgentRuntimeState = agentRuntimeState(forPanelId: panelId)
        removePendingTerminalInputObservers(forPanelId: panelId)
        let transferredRemoteCleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)?.cancel()
        discardAgentSessionPanelSubscription(panelId: panelId, panel: panel)
        discardBrowserPanelSubscription(panelId: panelId, panel: panel)
        removeBrowserOpenTabSuggestionIfNeeded(panel: panel, panelId: panelId)
        if cleanupControllerSurfaceState {
            TerminalController.shared.cleanupSurfaceState(surfaceIds: [panelId, tabId?.uuid].compactMap { $0 })
        }
        if closePanel {
            panel?.close()
        }

        let shouldPreserveRemoteDisconnectOnClose =
            origin == "tab_close" ||
            origin == "pane_close"
        if shouldPreserveRemoteDisconnectOnClose,
           panel is TerminalPanel {
            markRemoteTerminalSessionClosingIfLast(surfaceId: panelId)
        }
        let shouldRefreshRemoteDisconnectPlaceholder =
            shouldPreserveRemoteDisconnectOnClose &&
            remoteDisconnectPlaceholderPanelIds.remove(panelId) != nil &&
            panels.count == 1
        if shouldRefreshRemoteDisconnectPlaceholder,
           let remoteConfiguration {
            rememberPendingRemoteDisconnectReplacement(configuration: remoteConfiguration)
        }

        panels.removeValue(forKey: panelId)
        untrackRemoteTerminalSurface(panelId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
        removeSurfaceMappings(forPanelId: panelId)

        panelDirectories.removeValue(forKey: panelId)
        panelDirectoryDisplayLabels.removeValue(forKey: panelId)
        panelGitBranches.removeValue(forKey: panelId)
        panelPullRequests.removeValue(forKey: panelId)
        panelTitles.removeValue(forKey: panelId)
        panelCustomTitles.removeValue(forKey: panelId)
        panelCustomTitleSources.removeValue(forKey: panelId)
        pinnedPanelIds.remove(panelId)
        manualUnreadPanelIds.remove(panelId)
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        panelShellActivityStates.removeValue(forKey: panelId)
        clearAgentLifecycleStates(panelId: panelId)
        surfaceTTYNames.removeValue(forKey: panelId)
        discardRemotePTYSessionID(panelId: panelId)
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        surfaceListeningPorts.removeValue(forKey: panelId)
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
#if DEBUG
        debugSessionSnapshotScrollbackFallbackPanelIds.remove(panelId)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeValue(forKey: panelId)
#endif
        discardAgentRuntimeState(closedAgentRuntimeState)
        restoredAgentSnapshotsByPanelId.removeValue(forKey: panelId)
        restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
        terminalInheritanceFontPointsByPanelId.removeValue(forKey: panelId)
        if lastTerminalConfigInheritancePanelId == panelId {
            lastTerminalConfigInheritancePanelId = nil
        }
        if clearSurfaceNotifications {
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id, surfaceId: panelId)
        }

        if requestTransferredRemoteCleanup, let transferredRemoteCleanupConfiguration {
            Self.requestSSHControlMasterCleanupIfNeeded(configuration: transferredRemoteCleanupConfiguration)
        }
        return transferredRemoteCleanupConfiguration
    }
}

// MARK: - Live surface tty resolution

extension Workspace {
    /// Resolves the controlling tty name for a panel.
    ///
    /// For local terminal panels the live pty (via Ghostty) is authoritative:
    /// restored panes that run a launcher script never load shell integration,
    /// so they never report their tty, and a cached name can be stale or
    /// belong to another pane. When the live name is available it replaces the
    /// cached entry so every tty-keyed consumer (`debug.terminals`, `system.top`,
    /// claude-hook routing, the port scanner) sees the same value. Remote
    /// terminals and panels without a live pty fall back to the cached name.
    ///
    @discardableResult
    func liveSurfaceTTYName(panelId: UUID) -> String? {
        liveSurfaceTTYName(panelId: panelId, liveTTYNameProvider: { $0.surface.controllingTTYName() })
    }

    /// Test seam for ``liveSurfaceTTYName(panelId:)``: `liveTTYNameProvider`
    /// stands in for Ghostty's pty name lookup.
    @discardableResult
    func liveSurfaceTTYName(
        panelId: UUID,
        liveTTYNameProvider: (TerminalPanel) -> String?
    ) -> String? {
        let cached = surfaceTTYNames[panelId]
        guard !isRemoteWorkspace,
              !isRemoteTerminalSurface(panelId),
              let terminalPanel = terminalPanel(for: panelId),
              let live = Self.normalizedTTYName(liveTTYNameProvider(terminalPanel)) else {
            return cached
        }
        if live != cached {
            surfaceTTYNames[panelId] = live
            PortScanner.shared.registerTTY(workspaceId: id, panelId: panelId, ttyName: live)
        }
        return live
    }

    /// Normalizes `/dev/ttys012` or `ttys012` to the `ttys012` form used by
    /// shell-integration reports and the socket API.
    nonisolated static func normalizedTTYName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "not a tty" else {
            return nil
        }
        if trimmed.hasPrefix("/dev/") {
            let name = String(trimmed.dropFirst("/dev/".count))
            return name.isEmpty ? nil : name
        }
        return trimmed
    }
}

// MARK: - Pane cycling

extension Workspace {
    /// Focuses the pane `offset` steps away from the focused pane in layout
    /// order (bonsplit tree order, or Canvas order in Canvas layout), wrapping
    /// at both ends. When a pane is zoomed the zoom follows the focus so the
    /// shortcut works while one pane fills the window.
    ///
    /// Returns false when there is nothing to cycle to (a single pane).
    @discardableResult
    func focusAdjacentPane(offset: Int) -> Bool {
        guard offset != 0 else { return false }
        if layoutMode == .canvas {
            let ordered = orderedPanelIds
            guard ordered.count > 1 else { return false }
            let currentIndex = focusedPanelId.flatMap { ordered.firstIndex(of: $0) } ?? 0
            let target = ordered[Self.wrappedIndex(currentIndex + offset, count: ordered.count)]
            focusPanel(target)
            return true
        }

        let panes = bonsplitController.allPaneIds
        guard panes.count > 1 else { return false }
        let currentPaneId = bonsplitController.zoomedPaneId ?? bonsplitController.focusedPaneId
        let currentIndex = currentPaneId.flatMap { panes.firstIndex(of: $0) } ?? 0
        let targetPaneId = panes[Self.wrappedIndex(currentIndex + offset, count: panes.count)]
        guard targetPaneId != currentPaneId else { return false }

        let wasZoomed = bonsplitController.isSplitZoomed
        if let previousFocusedPanelId = focusedPanelId, let previous = panels[previousFocusedPanelId] {
            previous.unfocus()
        }
        if wasZoomed {
            _ = bonsplitController.clearPaneZoom()
        }
        bonsplitController.focusPane(targetPaneId)
        if wasZoomed {
            _ = bonsplitController.togglePaneZoom(inPane: targetPaneId)
        }
        if let tabId = bonsplitController.selectedTab(inPane: targetPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: targetPaneId)
        }
        return true
    }

    nonisolated static func wrappedIndex(_ index: Int, count: Int) -> Int {
        precondition(count > 0)
        let remainder = index % count
        return remainder < 0 ? remainder + count : remainder
    }
}


// MARK: - Focused-pane background

/// Paints the focused pane's terminal background a tad darker than the theme
/// background so the active pane reads as such without recoloring text. Done
/// with a standard OSC 11 background change injected into the pane's parser,
/// undone with OSC 111 when focus leaves. (A full identity-color background
/// with a light palette was tried first; grays, whites and reds in agent
/// output read badly on pastel, so only the tab strip carries the color now.)
enum PaneFocusColorScheme {
    /// How much darker the focused pane's background gets (0 = unchanged).
    static let focusedDarkening: CGFloat = 0.12

    static func hex(_ color: NSColor) -> String {
        let rgb = color.colorSpace.colorSpaceModel == .rgb ? color : (color.usingColorSpace(.sRGB) ?? color)
        return String(
            format: "%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }

    /// `base` scaled toward black by `focusedDarkening`.
    static func darkened(_ base: NSColor) -> NSColor {
        let rgb = base.colorSpace.colorSpaceModel == .rgb ? base : (base.usingColorSpace(.sRGB) ?? base)
        let factor = 1 - focusedDarkening
        return NSColor(
            calibratedRed: rgb.redComponent * factor,
            green: rgb.greenComponent * factor,
            blue: rgb.blueComponent * factor,
            alpha: 1
        )
    }

    private static func osc(_ body: String) -> String { "\u{1B}]\(body)\u{07}" }

    /// Sequence that sets the terminal background to the darkened theme color.
    static func activationSequence(themeBackground: NSColor) -> Data {
        Data(osc("11;#\(hex(darkened(themeBackground)))").utf8)
    }

    /// Sequence that restores the terminal's configured background.
    static let deactivationSequence = Data(osc("111").utf8)
}

extension Workspace {
    /// Minimum gap between chip refreshes driven by Enter presses, so holding
    /// the key never floods bonsplit with title updates.
    static let paneActionRefreshInterval: TimeInterval = 30

    /// Records that the user acted in this pane (pressed Enter: sent a message
    /// to an agent or ran a command). This is what the chip's age gauge
    /// measures; merely focusing a pane does not count.
    func notePaneAction(panelId: UUID, at now: Date = Date()) {
        guard panels[panelId] != nil else { return }
        let previous = panelLastFocusedAt[panelId]
        panelLastFocusedAt[panelId] = now
        if let previous, now.timeIntervalSince(previous) < Self.paneActionRefreshInterval {
            return
        }
        refreshTabTitleMarkers(panelId: panelId)
        notePaneActionOrderDidChange()
    }

    /// The action history (Cmd+[ / Cmd+], Recent Actions, sidebar) reads the
    /// stamps live; this nudges the menus and the sidebar to rebuild.
    func notePaneActionOrderDidChange() {
        NotificationCenter.default.post(name: .tabManagerFocusHistoryRevisionDidChange, object: nil)
    }

    /// Applies or clears the focused-pane background for a terminal panel.
    /// Idempotent per state, and the activation also stamps the panel's
    /// last-focus time so the tab age badge resets.
    func applyPaneFocusScheme(panelId: UUID, active: Bool) {
        let isApplied = paneFocusSchemeActivePanelIds.contains(panelId)
        guard active != isApplied else { return }
        guard let terminalPanel = terminalPanel(for: panelId), !isRemoteTerminalSurface(panelId) else { return }
        if active {
            paneFocusSchemeActivePanelIds.insert(panelId)
            terminalPanel.surface.processRemoteOutput(
                PaneFocusColorScheme.activationSequence(themeBackground: GhosttyApp.shared.defaultBackgroundColor)
            )
        } else {
            paneFocusSchemeActivePanelIds.remove(panelId)
            terminalPanel.surface.processRemoteOutput(PaneFocusColorScheme.deactivationSequence)
        }
    }
}


// MARK: - Grid arrangement (Spectacle-style)

/// Pure helpers for laying panes out as an even grid.
enum PaneGridArrangement {
    /// Splits `count` items into `groups` groups as evenly as possible, larger
    /// groups first: 7 items in 3 groups -> [3, 2, 2].
    static func groupSizes(count: Int, groups: Int) -> [Int] {
        guard count > 0, groups > 0 else { return [] }
        let groupCount = min(groups, count)
        let base = count / groupCount
        let remainder = count % groupCount
        return (0..<groupCount).map { $0 < remainder ? base + 1 : base }
    }
}

extension Workspace {
    /// Rebuilds the split tree as `rows` rows, each holding an even share of
    /// the workspace's panels side by side, then equalizes dividers.
    @discardableResult
    func arrangePanes(rows: Int) -> Bool {
        arrangePanes(groups: rows, groupOrientation: .vertical, cellOrientation: .horizontal)
    }

    /// Rebuilds the split tree as `columns` columns, each holding an even
    /// share of the workspace's panels stacked top to bottom, then equalizes.
    @discardableResult
    func arrangePanes(columns: Int) -> Bool {
        arrangePanes(groups: columns, groupOrientation: .horizontal, cellOrientation: .vertical)
    }

    /// Every panel keeps its own pane (one surface per pane) in the existing
    /// on-screen order; nothing is closed or created.
    private func arrangePanes(
        groups: Int,
        groupOrientation: SplitOrientation,
        cellOrientation: SplitOrientation
    ) -> Bool {
        guard layoutMode != .canvas, groups > 0 else { return false }
        let panelIds = orderedPanelIds.filter { panels[$0] != nil }
        guard panelIds.count > 1 else { return false }
        let previousFocus = focusedPanelId
        clearSplitZoom()

        // 1. Gather every surface into one pane; emptied panes close themselves.
        guard let anchor = bonsplitController.allPaneIds.first else { return false }
        for panelId in panelIds where paneId(forPanelId: panelId) != anchor {
            guard moveSurface(panelId: panelId, toPane: anchor, focus: false) else { return false }
        }
        for (index, panelId) in panelIds.enumerated() {
            _ = reorderSurface(panelId: panelId, toIndex: index, focus: false)
        }

        // 2. Peel off one pane per group along the primary axis.
        let sizes = PaneGridArrangement.groupSizes(count: panelIds.count, groups: groups)
        var groupPanes: [PaneID] = [anchor]
        var offset = sizes[0]
        var currentPane = anchor
        for size in sizes.dropFirst() {
            guard let tabId = surfaceIdFromPanelId(panelIds[offset]),
                  let newPane = bonsplitController.splitPane(
                      currentPane, orientation: groupOrientation, movingTab: tabId, insertFirst: false
                  ) else { return false }
            for panelId in panelIds[(offset + 1)..<(offset + size)] {
                guard moveSurface(panelId: panelId, toPane: newPane, focus: false) else { return false }
            }
            groupPanes.append(newPane)
            currentPane = newPane
            offset += size
        }

        // 3. Inside each group, give every surface its own cell along the other axis.
        offset = 0
        for (groupIndex, groupPane) in groupPanes.enumerated() {
            let members = panelIds[offset..<(offset + sizes[groupIndex])]
            var cellPane = groupPane
            for panelId in members.dropFirst() {
                guard let tabId = surfaceIdFromPanelId(panelId),
                      let newPane = bonsplitController.splitPane(
                          cellPane, orientation: cellOrientation, movingTab: tabId, insertFirst: false
                      ) else { return false }
                cellPane = newPane
            }
            offset += sizes[groupIndex]
        }

        // 4. Even dividers, then hand focus back. The pass runs again once
        // bonsplit has laid the new splits out: divider moves issued in the
        // same turn the splits were created are clamped against unsized
        // panes and leave the grid uneven (the same pass the Equalize Splits
        // shortcut runs fixes it a moment later, so we run exactly that).
        equalizeSplitsNow()
        if let previousFocus, panels[previousFocus] != nil {
            focusPanel(previousFocus)
        }
        scheduleTerminalGeometryReconcile()
        scheduleArrangeEqualizeRetry(attempt: 0)
        return true
    }

    /// The Equalize Splits pass, exactly what the shortcut and the menu run:
    /// plans even dividers from the current tree (leaf-weighted along each
    /// split's axis) and applies them. Returns true when every divider took
    /// its planned position.
    @discardableResult
    func equalizeSplitsNow() -> Bool {
        equalizeSplitsNow(using: PaneLayoutService())
    }

    @discardableResult
    func equalizeSplitsNow(using layout: PaneLayoutService) -> Bool {
        let result = layout.equalizeSplits(in: bonsplitController.treeSnapshot(), controller: bonsplitController)
        if result.foundSplit {
            didProgrammaticallyChangeSplitGeometry()
        }
        return result.didFullyEqualize
    }

    /// Delays between the settle passes, in seconds: next turn, then after
    /// the layout had time to size the panes.
    static let arrangeEqualizeRetryDelays: [TimeInterval] = [0, 0.1, 0.4, 1.0]

    private func scheduleArrangeEqualizeRetry(attempt: Int) {
        guard attempt < Self.arrangeEqualizeRetryDelays.count else { return }
        let delay = Self.arrangeEqualizeRetryDelays[attempt]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.layoutMode != .canvas else { return }
            let even = self.equalizeSplitsNow()
            self.scheduleTerminalGeometryReconcile()
            if !even {
                self.scheduleArrangeEqualizeRetry(attempt: attempt + 1)
            }
        }
    }
}


// MARK: - Last action from Claude transcripts

extension Workspace {
    /// Remembers the transcript file an agent hook reported for a panel.
    func noteTranscriptPath(_ path: String, panelId: UUID) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, panels[panelId] != nil else { return }
        panelTranscriptPathsByPanelId[panelId] = trimmed
    }

    /// The Claude session a panel is bound to, if any.
    func transcriptSessionId(forPanelId panelId: UUID) -> String? {
        guard let binding = surfaceResumeBindingsByPanelId[panelId] else { return nil }
        if let kind = binding.kind?.lowercased(), !kind.isEmpty, kind != "claude" { return nil }
        guard let checkpointId = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checkpointId.isEmpty else { return nil }
        return checkpointId
    }

    /// The transcript file for a panel: the hook-reported path when it still
    /// exists, else the session's file under `~/.claude/projects`.
    func transcriptURL(forPanelId panelId: UUID) -> URL? {
        if let path = panelTranscriptPathsByPanelId[panelId], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let sessionId = transcriptSessionId(forPanelId: panelId) else { return nil }
        return ClaudeTranscriptLastAction.transcriptURL(sessionId: sessionId)
    }

    /// Merges the transcript's last human message into the panel's
    /// last-action stamp. The later of the two wins, unless `replacing` is
    /// set, in which case the transcript date replaces whatever was stored
    /// (used once to retire stamps written before actions were tracked).
    /// Returns true when the stamp changed.
    @discardableResult
    func refreshLastActionFromTranscript(panelId: UUID, replacing: Bool = false) -> Bool {
        guard panels[panelId] != nil, let url = transcriptURL(forPanelId: panelId),
              let transcriptDate = ClaudeTranscriptLastAction.lastHumanMessageDate(in: url) else { return false }
        let stored = panelLastFocusedAt[panelId]
        if !replacing, let stored, stored >= transcriptDate { return false }
        if stored == transcriptDate { return false }
        panelLastFocusedAt[panelId] = transcriptDate
        refreshTabTitleMarkers(panelId: panelId)
        notePaneActionOrderDidChange()
        return true
    }

    /// Runs the transcript merge over every panel. Returns the panels whose
    /// stamp changed.
    @discardableResult
    func refreshLastActionsFromTranscripts(replacing: Bool = false) -> [UUID] {
        orderedPanelIds.filter { refreshLastActionFromTranscript(panelId: $0, replacing: replacing) }
    }
}
