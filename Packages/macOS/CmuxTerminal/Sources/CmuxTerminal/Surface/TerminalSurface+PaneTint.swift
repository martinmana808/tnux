public import AppKit

// MARK: - Pane identity tint

extension TerminalSurface {
    /// Sets this pane's identity tint and repaints the attached view's
    /// backdrop. A no-op when the color is unchanged, so callers on a title
    /// refresh path can write it unconditionally.
    ///
    /// The surface only carries the color; how far it is blended into the
    /// terminal background is the hosting view's decision.
    @MainActor
    public func setPaneTintColor(_ color: NSColor?) {
        guard paneTintColor != color else { return }
        paneTintColor = color
        attachedView?.applySurfaceBackground()
    }
}
