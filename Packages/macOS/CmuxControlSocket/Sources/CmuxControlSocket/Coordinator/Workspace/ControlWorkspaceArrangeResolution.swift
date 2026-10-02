public import Foundation

/// The outcome of `workspace.arrange_panes`.
public enum ControlWorkspaceArrangeResolution: Sendable, Equatable {
    /// No TabManager resolved.
    case tabManagerUnavailable
    /// No workspace resolved from the routing selectors.
    case notFound
    /// Neither `rows` nor `columns` (a positive integer) was supplied.
    case invalidParams
    /// The grid was rebuilt. `arranged` is false when the workspace had
    /// nothing to arrange (a single pane, or Canvas layout).
    case resolved(workspaceID: UUID, arranged: Bool)
}
