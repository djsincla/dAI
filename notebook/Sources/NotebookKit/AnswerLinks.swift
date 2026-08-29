import Foundation

/// Finding, in an answer, the places where it names its sources.
///
/// The model is asked to cite by name, so answers say things like "as described
/// in (vmware-cloud-foundation-9-1.pdf p2518 (2/6))". Those names are the only
/// bridge between a claim and the page it came from, and they were dead text:
/// the reader could see which passage was meant and had no way to go there
/// short of finding the same string in the strip above and clicking that.
///
/// **Matching is deliberately conservative.** A wrong link is worse than a
/// missing one here, because a citation that opens the wrong page is a citation
/// that quietly says the wrong thing about where a claim came from. So this
/// only matches names it was actually given, never a guess at what a name might
/// have been shortened to.
public enum AnswerLinks {

    /// One place an answer named a source.
    public struct Found: Equatable, Sendable {
        /// Where in the answer.
        public let range: Range<String.Index>
        /// Which of the turn's citations it named.
        public let citation: Int

        public init(range: Range<String.Index>, citation: Int) {
            self.range = range
            self.citation = citation
        }
    }

    /// Every citation named in the answer, in the order they appear.
    ///
    /// Overlaps are resolved in favour of the longer match, so a citation whose
    /// name contains another citation's name links to the one the writer meant
    /// rather than to whichever was checked first.
    public static func find(in answer: String,
                            citations: [String]) -> [Found] {
        guard !answer.isEmpty, !citations.isEmpty else { return [] }

        var found: [Found] = []
        for (index, citation) in citations.enumerated() {
            for name in names(of: citation) {
                found.append(contentsOf: occurrences(of: name, in: answer)
                    .map { Found(range: $0, citation: index) })
            }
        }

        // Longest first, so that when two matches cover the same text the more
        // specific one survives the overlap check below.
        found.sort {
            let left = answer.distance(from: $0.range.lowerBound, to: $0.range.upperBound)
            let right = answer.distance(from: $1.range.lowerBound, to: $1.range.upperBound)
            if left != right { return left > right }
            return $0.range.lowerBound < $1.range.lowerBound
        }

        var kept: [Found] = []
        for candidate in found where !kept.contains(where: { overlaps($0.range, candidate.range) }) {
            kept.append(candidate)
        }
        return kept.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The forms of a citation worth looking for.
    ///
    /// The full name, and the name without its part suffix. A citation reads
    /// "notes.pdf p12 (2/6)" because the page produced six chunks, and a model
    /// quoting it in a sentence routinely drops the part, since the part is
    /// about this index rather than about the document. Nothing shorter than
    /// that is tried: trimming further starts matching ordinary words.
    static func names(of citation: String) -> [String] {
        let full = citation.trimmingCharacters(in: .whitespaces)
        guard !full.isEmpty else { return [] }
        var out = [full]
        if let open = full.lastIndex(of: "("), full.hasSuffix(")") {
            let without = String(full[full.startIndex ..< open])
                .trimmingCharacters(in: .whitespaces)
            // Only if what is left is still substantial. "(2/6)" removed from
            // "p12 (2/6)" leaves "p12", which is short enough to appear in
            // prose by accident.
            if without.count >= 8, without != full { out.append(without) }
        }
        return out
    }

    private static func occurrences(of needle: String,
                                    in haystack: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = haystack.startIndex
        while from < haystack.endIndex,
              let range = haystack.range(of: needle, options: .caseInsensitive,
                                         range: from ..< haystack.endIndex) {
            out.append(range)
            from = range.upperBound
        }
        return out
    }

    private static func overlaps(_ a: Range<String.Index>,
                                 _ b: Range<String.Index>) -> Bool {
        a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }
}
