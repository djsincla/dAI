import AppKit
import SwiftUI

/// The app's colours, in one place and named for what they mean.
///
/// **Every surface used to be `.quaternary` at a slightly different opacity**:
/// 0.12 for a turn, 0.14 for its citations, 0.18 for the ask bar. Three alphas
/// of one grey is not a hierarchy, it is the absence of one, and the result read
/// as a flat sheet of boxes with nothing to say which mattered.
///
/// So these are named by role rather than by shade. A surface is `card` or
/// `evidence` or `field`, and what colour those are is decided here once. The
/// rule that keeps it honest: **a view never names a colour, only a role.**
///
/// The accent is teal and it is the app's own, not the system's. `.tint`
/// inherits whatever accent colour the user set in System Settings, so the one
/// colour carrying meaning here changed depending on an unrelated preference.
///
/// The neutrals are teal biased rather than pure grey. A pure grey beside a
/// saturated accent reads as unconsidered; shifting the greys a few degrees
/// toward the accent is what makes the whole surface look chosen. It is subtle
/// on purpose: nobody should be able to name the colour of the background.
enum Palette {

    // ------------------------------------------------------------ the accent

    /// Deep enough to sit under black text on white, bright enough to read on a
    /// dark ground. The two are not the same hue by accident: the dark variant
    /// is lifted and desaturated slightly, because a colour that is correct on
    /// white glows on black.
    static let accent = dynamic(light: 0x0D6E68, dark: 0x2DD4BF)

    /// The accent at the weight a large area can carry without shouting.
    static let accentSoft = dynamic(light: 0x0D6E68, dark: 0x2DD4BF, alpha: 0.12)
    static let accentEdge = dynamic(light: 0x0D6E68, dark: 0x2DD4BF, alpha: 0.30)

    // ----------------------------------------------------------- the surfaces

    /// A recorded turn. Raised off the page, with a hairline rather than a
    /// heavier fill: the answer is the content, and a loud container competes
    /// with it.
    static let card = dynamic(light: 0x0F3B38, dark: 0x7FD9D2, alpha: 0.05)
    static let cardEdge = dynamic(light: 0x0F3B38, dark: 0x7FD9D2, alpha: 0.14)

    /// Retrieved passages. Tinted toward the accent because this is the
    /// machine's own working shown to the reader, and it should look like a
    /// different kind of thing from the prose above it.
    static let evidence = dynamic(light: 0x0D6E68, dark: 0x2DD4BF, alpha: 0.07)

    /// Anything typed into.
    static let field = dynamic(light: 0x0F3B38, dark: 0x7FD9D2, alpha: 0.07)
    static let fieldEdge = dynamic(light: 0x0F3B38, dark: 0x7FD9D2, alpha: 0.18)

    // ----------------------------------------------------------- the meanings

    /// Cut off, capped, stopped early. Amber rather than red: nothing failed,
    /// the answer is real and incomplete, and red would say the wrong thing.
    static let warning = dynamic(light: 0x9A5B00, dark: 0xF5B851)
    static let warningSoft = dynamic(light: 0xB8730A, dark: 0xF5B851, alpha: 0.14)

    /// Something went wrong and the result cannot be trusted.
    static let danger = dynamic(light: 0xA3231B, dark: 0xFF6B5E)

    /// Reached, loaded, ready.
    static let ok = dynamic(light: 0x136B3A, dark: 0x54D98C)

    // --------------------------------------------------------------- building

    /// A colour that resolves per appearance.
    ///
    /// `NSColor(name:dynamicProvider:)` rather than two static colours picked at
    /// call time: it re-resolves when the appearance changes, so switching the
    /// system to dark repaints instead of leaving one theme's ink on the
    /// other's ground.
    static func dynamic(light: Int, dark: Int, alpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light, alpha: alpha)
        })
    }
}

private extension NSColor {
    convenience init(rgb: Int, alpha: Double) {
        self.init(srgbRed: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  alpha: alpha)
    }
}
