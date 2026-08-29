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
    static let accentSoft = dynamic(light: 0x0D6E68, dark: 0x2DD4BF,
                                    alpha: 0.10, darkAlpha: 0.14)
    static let accentEdge = dynamic(light: 0x0D6E68, dark: 0x2DD4BF, alpha: 0.45)

    // ----------------------------------------------------------- the surfaces

    /// The ground the record sits on.
    ///
    /// **Value, not hue, is what makes a surface hierarchy.** The first attempt
    /// here put page, card and evidence inside a seven point lightness band and
    /// relied on tint to separate them, which is the same mistake as three
    /// alphas of one grey wearing a better coat. Page to card is now about ten
    /// points of L*, which is a step you can see without being told to look.
    static let page = dynamic(light: 0xE5EDEC, dark: 0x0C1211)

    /// A recorded turn: raised off the page, not sunk into it.
    static let card = dynamic(light: 0xFFFFFF, dark: 0x1C2624)

    /// **An edge supports a surface, it does not replace one.** At full alpha
    /// the first edge was three times stronger than the page to card step it
    /// outlined, so the eye read boxes drawn on a sheet. In dark it was
    /// saturated teal, which is the loudest way to say unfinished.
    static let cardEdge = dynamic(light: 0x0F3B38, dark: 0xFFFFFF,
                                  alpha: 0.12, darkAlpha: 0.09)

    /// Two shadows, contact and ambient. One shadow reads as a sticker.
    static let cardShadow = dynamic(light: 0x0B2E2C, dark: 0x000000,
                                    alpha: 0.10, darkAlpha: 0.40)
    static let cardShadowWide = dynamic(light: 0x0B2E2C, dark: 0x000000,
                                        alpha: 0.05, darkAlpha: 0.22)

    /// Retrieved passages: a band, not a panel.
    ///
    /// Filling it made a third nested surface, card inside page inside
    /// evidence, which is what turns a record into boxes in boxes. The mono
    /// figures and the teal already say this is a different kind of thing; the
    /// fill was saying it twice and spending a whole level of hierarchy to do
    /// it.
    static let evidence = dynamic(light: 0x0F3B38, dark: 0xFFFFFF, alpha: 0.035)
    static let evidenceRule = dynamic(light: 0x0F3B38, dark: 0xFFFFFF,
                                      alpha: 0.14, darkAlpha: 0.11)

    /// Anything typed into.
    static let field = dynamic(light: 0xFFFFFF, dark: 0x1C2624)
    static let fieldEdge = dynamic(light: 0x0F3B38, dark: 0xFFFFFF,
                                   alpha: 0.16, darkAlpha: 0.14)

    /// A chosen row, drawn by us rather than by AppKit.
    ///
    /// `List(selection:)` paints its highlight from the system accent and the
    /// SwiftUI tint does not reach it, so a teal app had a blue sidebar. Owning
    /// the row is the only way to fix that without an asset catalogue, and the
    /// binding was already doing nothing else: the rows set the selection
    /// themselves.
    static let selection = dynamic(light: 0x0D6E68, dark: 0x2DD4BF,
                                   alpha: 0.16, darkAlpha: 0.20)
    /// The same row when the window is not frontmost.
    static let selectionIdle = dynamic(light: 0x0F3B38, dark: 0xFFFFFF,
                                       alpha: 0.08, darkAlpha: 0.07)

    // --------------------------------------------------------------- the inks

    /// **Text has to come from the same palette as what is behind it.**
    /// `.secondary` and `.tertiary` are neutral black at fixed alphas, and a
    /// desaturated grey on a tinted ground goes dusty rather than quiet. That
    /// is what washed out means, and `.tertiary` on this page measured about
    /// three to one, under the readable minimum.
    static let ink = dynamic(light: 0x101A19, dark: 0xE8F0EE)
    static let inkSecondary = dynamic(light: 0x3D4E4C, dark: 0x9DB0AD)
    static let inkTertiary = dynamic(light: 0x637472, dark: 0x7A8C89)

    // ----------------------------------------------------------- the meanings

    /// Cut off, capped, stopped early. Amber rather than red: nothing failed,
    /// the answer is real and incomplete, and red would say the wrong thing.
    static let warning = dynamic(light: 0x8A5200, dark: 0xF5B851)
    static let warningSoft = dynamic(light: 0x8A5200, dark: 0xF5B851,
                                     alpha: 0.10, darkAlpha: 0.14)

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
    /// A colour that resolves per appearance.
    ///
    /// `darkAlpha` defaults to `alpha` and exists because the two appearances
    /// are not mirror images: a white overlay on a dark ground reads weaker
    /// than a black one on a light ground at the same alpha, so an edge that is
    /// right in light is invisible in dark at the same number.
    static func dynamic(light: Int, dark: Int, alpha: Double = 1,
                        darkAlpha: Double? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light,
                           alpha: isDark ? (darkAlpha ?? alpha) : alpha)
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
