import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@Suite struct TerminalSurfacePaneTintTests {
    private static let themeBackground = NSColor(deviceRed: 0.157, green: 0.173, blue: 0.204, alpha: 1)

    @Test func tintDoesNotBrightenTheBackground() {
        let tinted = TerminalSurfacePaneTint.tinted(
            Self.themeBackground,
            with: NSColor(deviceRed: 0.71, green: 0.98, blue: 0.78, alpha: 1)
        )

        // The regression this guards: blending toward the pastel tab color
        // itself lifted every channel ~8% and washed the pane out. A tinted
        // pane must never end up brighter than an untinted one — landing a
        // shade darker is fine (the hue shift moves which channel dominates).
        #expect(tinted.brightnessComponent <= Self.themeBackground.brightnessComponent)
        #expect(tinted.brightnessComponent > Self.themeBackground.brightnessComponent - 0.05)
    }

    @Test func tintIsVisiblyColoredNotJustAHint() {
        let tinted = TerminalSurfacePaneTint.tinted(
            Self.themeBackground,
            with: NSColor(deviceRed: 0.71, green: 0.98, blue: 0.78, alpha: 1)
        )

        // Dark is not enough — it also has to read as green rather than gray.
        #expect(tinted.saturationComponent > Self.themeBackground.saturationComponent)
        #expect(tinted.saturationComponent > 0.2)
    }

    @Test func tintShiftsTowardTheTintHue() {
        let green = NSColor(deviceRed: 0.71, green: 0.98, blue: 0.78, alpha: 1)
        let tinted = TerminalSurfacePaneTint.tinted(Self.themeBackground, with: green)

        // The whole point: a green tab color makes green the dominant channel
        // shift, so two panes with different colors are distinguishable.
        let greenShift = tinted.greenComponent - Self.themeBackground.greenComponent
        let blueShift = tinted.blueComponent - Self.themeBackground.blueComponent
        #expect(greenShift > blueShift)
        #expect(greenShift > 0)
    }

    @Test func distinctTabColorsProduceDistinctBackdrops() {
        let red = TerminalSurfacePaneTint.tinted(
            Self.themeBackground,
            with: NSColor(deviceRed: 0.98, green: 0.71, blue: 0.71, alpha: 1)
        )
        let blue = TerminalSurfacePaneTint.tinted(
            Self.themeBackground,
            with: NSColor(deviceRed: 0.71, green: 0.78, blue: 0.98, alpha: 1)
        )

        #expect(red.redComponent > blue.redComponent)
        #expect(blue.blueComponent > red.blueComponent)
    }

    @Test func zeroWeightLeavesBackgroundUnchanged() {
        let tinted = TerminalSurfacePaneTint.tinted(
            Self.themeBackground,
            with: .systemPink,
            weight: 0
        )

        #expect(abs(tinted.redComponent - Self.themeBackground.redComponent) < 0.0001)
        #expect(abs(tinted.greenComponent - Self.themeBackground.greenComponent) < 0.0001)
        #expect(abs(tinted.blueComponent - Self.themeBackground.blueComponent) < 0.0001)
    }

    @Test func fullWeightYieldsTheHueAtBackgroundBrightness() {
        let pink = NSColor(deviceRed: 0.9, green: 0.4, blue: 0.6, alpha: 1)
        let tinted = TerminalSurfacePaneTint.tinted(Self.themeBackground, with: pink, weight: 1)

        // Even at full weight the pane never becomes the bright tab color:
        // it becomes that color's hue, at the theme's own brightness.
        #expect(abs(tinted.hueComponent - pink.hueComponent) < 0.01)
        #expect(abs(tinted.brightnessComponent - Self.themeBackground.brightnessComponent) < 0.0001)
        #expect(abs(tinted.saturationComponent - TerminalSurfacePaneTint.tintSaturation) < 0.0001)
    }

    @Test func backgroundAlphaSurvivesTheBlend() {
        let translucent = Self.themeBackground.withAlphaComponent(0.65)
        let tinted = TerminalSurfacePaneTint.tinted(translucent, with: .systemTeal)

        #expect(abs(tinted.alphaComponent - 0.65) < 0.0001)
    }
}
