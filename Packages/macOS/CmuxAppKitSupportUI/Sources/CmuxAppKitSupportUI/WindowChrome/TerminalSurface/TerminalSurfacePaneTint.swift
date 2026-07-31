public import AppKit

/// Derives a pane's terminal backdrop from its assigned tab color.
///
/// Each pane carries a bright, pastel identity color — the one its tab chip is
/// painted with, chosen for black text to read on. Blending that color itself
/// into the background would mostly *brighten* the pane (a 0.98-brightness
/// pastel raises every channel), producing a washed-out gray rather than a
/// dark colored one.
///
/// So only the pane color's **hue** is borrowed. It is re-anchored to the
/// background's own brightness before blending, which means the result is the
/// theme background shifted in color at constant luminance: a dark green pane
/// for a green tab, exactly as dark as an untinted pane. Because the anchor is
/// recomputed from the resolved theme background, it follows theme switches
/// for free.
public enum TerminalSurfacePaneTint {
    /// How far a pane's backdrop moves from the theme background toward its
    /// hue-anchored pane color. Larger than it looks: since the move is
    /// sideways in color rather than upward in brightness, it colors the pane
    /// without ever competing with terminal text.
    public static let defaultWeight: CGFloat = 0.35

    /// Saturation of the hue-anchored tint target. The pane colors themselves
    /// are deliberately desaturated so black tab text reads on them; at
    /// terminal-background brightness that much saturation would be invisible,
    /// so the anchor re-saturates before blending.
    public static let tintSaturation: CGFloat = 0.55

    /// Blends `tint`'s hue into `background` by `weight` (0 = unchanged
    /// background, 1 = the fully saturated hue at the background's brightness),
    /// preserving the background's alpha so surface opacity settings survive.
    ///
    /// - Parameters:
    ///   - background: The theme's resolved terminal background color.
    ///   - tint: The pane's assigned tab color; only its hue is used.
    ///   - weight: Blend fraction, clamped to `0...1`.
    /// - Returns: The tinted backdrop, or `background` unchanged when either
    ///   color cannot be converted to a component-wise RGB color space.
    ///   A pure black background stays black — there is no brightness to tint.
    public static func tinted(
        _ background: NSColor,
        with tint: NSColor,
        weight: CGFloat = defaultWeight
    ) -> NSColor {
        guard
            let base = background.usingColorSpace(.deviceRGB),
            let target = tint.usingColorSpace(.deviceRGB)
        else {
            return background
        }
        let anchored = NSColor(
            deviceHue: target.hueComponent,
            saturation: tintSaturation,
            brightness: base.brightnessComponent,
            alpha: 1
        )
        let amount = min(max(weight, 0), 1)
        return NSColor(
            deviceRed: base.redComponent + (anchored.redComponent - base.redComponent) * amount,
            green: base.greenComponent + (anchored.greenComponent - base.greenComponent) * amount,
            blue: base.blueComponent + (anchored.blueComponent - base.blueComponent) * amount,
            alpha: base.alphaComponent
        )
    }
}
