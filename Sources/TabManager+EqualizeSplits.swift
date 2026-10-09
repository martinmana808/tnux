import CmuxPanes
import Foundation

extension TabManager {
    /// Equalize splits - not directly supported by bonsplit.
    func equalizeSplits(tabId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }

        let result = equalizeSplitsOnce(in: tab)
        if result.foundSplit {
            tab.didProgrammaticallyChangeSplitGeometry()
        }
        return result.didFullyEqualize
    }

    @discardableResult
    private func equalizeSplitsOnce(in tab: Workspace) -> SplitEqualizeResult {
        paneLayout.equalizeSplits(
            in: tab.bonsplitController.treeSnapshot(),
            controller: tab.bonsplitController
        )
    }
}


// MARK: - Automatic workspace identity colors

/// Picks workspace colors from the user's palette so every workspace gets one
/// without manual setup; the color drives the sidebar highlight and the dot
/// before the workspace name.
enum WorkspaceAutoColor {
    /// The least-used palette entry (ties broken by palette order), so colors
    /// spread out across workspaces instead of clustering.
    static func nextHex(palette: [String], used: [String]) -> String? {
        guard !palette.isEmpty else { return nil }
        let normalizedUsed = used.map { $0.uppercased() }
        var best: (hex: String, count: Int)?
        for hex in palette {
            let count = normalizedUsed.filter { $0 == hex.uppercased() }.count
            if best == nil || count < best!.count { best = (hex, count) }
        }
        return best?.hex
    }
}

extension TabManager {
    /// Gives `workspace` a palette color when it has none.
    func assignWorkspaceColorIfNeeded(_ workspace: Workspace) {
        guard workspace.customColor == nil else { return }
        let palette = WorkspaceTabColorSettings.palette().map(\.hex)
        let used = tabs.compactMap(\.customColor)
        guard let hex = WorkspaceAutoColor.nextHex(palette: palette, used: used) else { return }
        workspace.setCustomColor(hex)
    }

    /// Colors every colorless workspace. Opt-in: Tnux no longer colors
    /// workspaces by default; pick a color from the workspace context menu.
    func assignWorkspaceColorsWhereMissing() {
        for tab in tabs { assignWorkspaceColorIfNeeded(tab) }
    }

    private static let autoColorsClearedDefaultsKey = "tnux.autoWorkspaceColorsCleared.v1"

    /// One-time cleanup for installs that ran the auto-coloring build: clears
    /// every workspace color so the sidebar starts uncolored, then never runs
    /// again. Colors picked by hand afterwards are untouched.
    func clearAutoAssignedWorkspaceColorsOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.autoColorsClearedDefaultsKey) else { return }
        defaults.set(true, forKey: Self.autoColorsClearedDefaultsKey)
        for tab in tabs where tab.customColor != nil {
            tab.setCustomColor(nil)
        }
    }
}
