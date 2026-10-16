import AppKit
import Bonsplit
import SwiftUI

/// Row actions handed to pane rows as closures, never the store itself.
struct SidebarPaneRowActions {
    let select: (SidebarPaneRow) -> Void
}

/// One pane row: identity dot, status glyph, `folder — title`, and a small
/// age gauge with the tab chip's semantics (full = acted on today).
struct SidebarPaneRowView: View, Equatable {
    let row: SidebarPaneRow
    let showsWorkspace: Bool
    let fontScale: CGFloat
    let now: Date
    let actions: SidebarPaneRowActions

    nonisolated static func == (lhs: SidebarPaneRowView, rhs: SidebarPaneRowView) -> Bool {
        lhs.row == rhs.row && lhs.showsWorkspace == rhs.showsWorkspace && lhs.fontScale == rhs.fontScale && lhs.now == rhs.now
    }

    @State private var isHovered = false

    var body: some View {
        let fill = row.lastActionAt.map { BonsplitPaneAge.fill(since: $0, now: now) } ?? 0
        Button {
            actions.select(row)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(row.color)
                    .frame(width: 7, height: 7)
                statusGlyph
                    .frame(width: 12, height: 12)
                if showsWorkspace, !row.workspaceTitle.isEmpty {
                    Text(row.workspaceTitle)
                        .cmuxFont(size: 11 * fontScale, weight: .regular)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .layoutPriority(0)
                }
                Text(row.title)
                    .cmuxFont(size: 11.5 * fontScale, weight: row.isFocused ? .semibold : .regular)
                    .foregroundStyle(row.isFocused ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                SidebarPaneAgeGauge(color: row.color, fill: fill)
                    .frame(width: 26, height: 6)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(row.isFocused ? row.color.opacity(0.22) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .safeHelp(BonsplitPaneAge.tooltip(lastActionAt: row.lastActionAt, now: now))
        .accessibilityIdentifier("sidebarPane.\(row.id.uuidString)")
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch row.status {
        case .needsInput:
            CmuxSystemSymbolImage(magnified: "bell.fill", pointSize: 9, weight: .semibold)
                .foregroundStyle(Color.orange)
        case .running:
            CmuxSystemSymbolImage(magnified: "bolt.fill", pointSize: 9, weight: .semibold)
                .foregroundStyle(Color.yellow)
        case .idle, .none:
            Color.clear
        }
    }
}

/// A capsule whose colored fill shrinks from the right as the pane ages.
struct SidebarPaneAgeGauge: View {
    let color: Color
    let fill: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().strokeBorder(color.opacity(0.7), lineWidth: 1)
                Capsule().fill(color)
                    .frame(width: max(0, geometry.size.width * CGFloat(min(1, max(0, fill)))))
            }
        }
    }
}

/// "Needs input" / "Running" block above the workspace list.
struct SidebarPaneSectionView: View {
    let title: String
    let rows: [SidebarPaneRow]
    let fontScale: CGFloat
    let now: Date
    let actions: SidebarPaneRowActions

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .cmuxFont(size: 10.5 * fontScale, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                ForEach(rows) { row in
                    SidebarPaneRowView(row: row, showsWorkspace: true, fontScale: fontScale, now: now, actions: actions)
                        .equatable()
                        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Pane rows under a workspace: all of them when expanded, or just the
/// focused one as an Arc-style peek when collapsed.
struct SidebarWorkspacePaneRows: View {
    let rows: [SidebarPaneRow]
    let indent: CGFloat
    let fontScale: CGFloat
    let now: Date
    let actions: SidebarPaneRowActions

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(rows) { row in
                    SidebarPaneRowView(row: row, showsWorkspace: false, fontScale: fontScale, now: now, actions: actions)
                        .equatable()
                }
            }
            .padding(.leading, indent + 14)
            .padding(.trailing, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The disclosure chevron drawn at the leading edge of a workspace row.
struct SidebarWorkspaceChevron: View {
    let isExpanded: Bool
    let paneCount: Int
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            CmuxSystemSymbolImage(magnified: isExpanded ? "chevron.down" : "chevron.right", pointSize: 8, weight: .bold)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 12, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .safeHelp(isExpanded
            ? String(localized: "sidebar.panes.hidePanes", defaultValue: "Hide panes")
            : String(localized: "sidebar.panes.showPanes", defaultValue: "Show panes"))
        .accessibilityLabel(isExpanded
            ? String(localized: "sidebar.panes.hidePanes", defaultValue: "Hide panes")
            : String(localized: "sidebar.panes.showPanes", defaultValue: "Show panes"))
        .opacity(paneCount > 0 ? 1 : 0)
    }
}

/// Expand/Collapse all, View all, and Sort: the always-visible controls.
struct SidebarPanesControls: View {
    @ObservedObject var preferences: SidebarPanesPreferences
    let workspaceIds: [UUID]

    var body: some View {
        let allExpanded = preferences.allExpanded(workspaceIds)
        HStack(spacing: 2) {
            control(
                symbol: allExpanded ? "chevron.up.chevron.down" : "chevron.down.chevron.up",
                label: allExpanded ? SidebarPanesStrings.collapseAll : SidebarPanesStrings.expandAll,
                isOn: false
            ) {
                preferences.toggleAll(workspaceIds)
            }
            .disabled(preferences.viewAll)
            control(
                symbol: "list.bullet.rectangle",
                label: preferences.viewAll ? SidebarPanesStrings.viewByWorkspace : SidebarPanesStrings.viewAll,
                isOn: preferences.viewAll
            ) {
                preferences.viewAll.toggle()
            }
            control(
                symbol: "clock.arrow.circlepath",
                label: preferences.sort == .lastPrompted ? SidebarPanesStrings.sortLayout : SidebarPanesStrings.sortLastPrompted,
                isOn: preferences.sort == .lastPrompted
            ) {
                preferences.sort = preferences.sort == .lastPrompted ? .layout : .lastPrompted
            }
        }
    }

    private func control(symbol: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CmuxSystemSymbolImage(magnified: symbol, pointSize: 11, weight: .medium)
                .foregroundStyle(isOn ? cmuxAccentColor() : Color(nsColor: .secondaryLabelColor))
                .frame(width: 22, height: 22, alignment: .center)
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22, alignment: .center)
        .safeHelp(label)
        .accessibilityLabel(label)
    }
}

/// Shared strings for the sidebar controls, the Panes menu and the palette.
enum SidebarPanesStrings {
    static var expandAll: String { String(localized: "sidebar.panes.expandAll", defaultValue: "Expand All Workspaces") }
    static var collapseAll: String { String(localized: "sidebar.panes.collapseAll", defaultValue: "Collapse All Workspaces") }
    static var viewAll: String { String(localized: "sidebar.panes.viewAll", defaultValue: "View All Panes") }
    static var viewByWorkspace: String { String(localized: "sidebar.panes.viewByWorkspace", defaultValue: "View Panes by Workspace") }
    static var sortLayout: String { String(localized: "sidebar.panes.sort.layout", defaultValue: "Sort Panes by Layout") }
    static var sortLastPrompted: String { String(localized: "sidebar.panes.sort.lastPrompted", defaultValue: "Sort Panes by Last Prompted") }
    static var needsInput: String { String(localized: "menu.panes.needsInput", defaultValue: "Needs Input") }
    static var running: String { String(localized: "menu.panes.running", defaultValue: "Running") }
}
