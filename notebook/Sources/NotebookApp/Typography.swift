import SwiftUI

/// The type scale, in one place and named for what it sets.
///
/// **The default ladder was compressed to the point of meaninglessness.**
/// Question at title3 (15) over answer at body (13) is a ratio of 1.15, which
/// is not a heading, it is slightly larger text. Everything on screen was SF
/// Pro regular in one of three greys, so a reader skimming for "which of this
/// is the machine's working and which is the answer" got no signal from the
/// type at all, only from a background colour too faint to see.
///
/// The scale is 20 / 15 / 12 / 11, and the work is done by register as much as
/// by size: semibold sans for the question, serif for generated prose,
/// monospace for anything that is a value rather than a sentence. Three
/// registers for three kinds of text, and no colour spent saying so.
///
/// Fixed sizes rather than text styles, because macOS has no meaningful
/// Dynamic Type and because a column of scores has to stay aligned.
enum Type {

    /// 20 semibold. The question is what indexes the record: scrolling a
    /// hundred turns, it is the only thing that has to be findable without
    /// being read.
    static let question = Font.system(size: 20, weight: .semibold)

    /// New York at 15.
    ///
    /// The one register change that does the most work. Generated prose becomes
    /// visibly a different kind of text from every other string in the window,
    /// which is honest: it is the only text here that a model wrote. NY has a
    /// large x height, was drawn for this size, and reads better than SF across
    /// a long measure.
    static let answer = Font.system(size: 15, weight: .regular, design: .serif)

    /// The passage a claim came from.
    static let citation = Font.system(size: 12, weight: .regular)

    /// The score. Medium rather than regular: it is the number people came for.
    static let score = Font.system(size: 12, weight: .medium, design: .monospaced)

    /// Facts about the run. Monospaced because they are values rather than
    /// prose, and so that the same fact lines up down a column of turns.
    static let provenance = Font.system(size: 11, weight: .regular,
                                        design: .monospaced)

    /// The one fact that changes what the answer means.
    static let stateBadge = Font.system(size: 10, weight: .semibold,
                                        design: .monospaced)

    /// The turn's number, hanging outside the text column.
    static let ordinal = Font.system(size: 11, weight: .medium,
                                     design: .monospaced)

    static let rowTitle = Font.system(size: 13, weight: .medium)
    /// Counts, so the digits align down the list.
    static let rowDetail = Font.system(size: 11, weight: .regular,
                                       design: .monospaced)
}
