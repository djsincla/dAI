import NotebookKit
import SwiftUI

/// The answer, with the sources it names made reachable.
///
/// The model is asked to cite by name, so an answer says "as described in
/// (vcf-9-1.pdf p2518 (2/6))" and that name was dead text. The reader could see
/// exactly which passage was meant and had to go and find the same string in
/// the strip above to open it. Every citation in the strip has always been one
/// click from its page; the ones inside the sentence were the only ones that
/// were not.
///
/// **Only names the answer actually used become links.** A citation that was
/// retrieved but never mentioned is not linked into the prose at some plausible
/// place, because a link is a claim that this sentence came from that page, and
/// inventing it would be inventing provenance.
struct AnswerView: View {
    let answer: String
    let citations: [NotebookPackage.Turn.Citation]
    var open: (NotebookPackage.Turn.Citation) -> Void

    var body: some View {
        Text(linked)
            .font(Type.answer)
            .lineSpacing(5)
            .foregroundStyle(Palette.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tint(Palette.accent)
            // Intercepted rather than handed to the system. These are not web
            // addresses; the scheme exists only to carry an index from the
            // attributed string back to here, and letting one escape to the
            // browser would be a confusing way to fail.
            .environment(\.openURL, OpenURLAction { url in
                guard let index = Self.index(of: url),
                      citations.indices.contains(index) else { return .discarded }
                open(citations[index])
                return .handled
            })
    }

    /// The answer with its citation names marked as links.
    private var linked: AttributedString {
        var attributed = AttributedString(answer)
        let found = AnswerLinks.find(in: answer, citations: citations.map(\.citation))
        // Applied back to front, so that ranges converted from the plain string
        // are still valid as earlier ones are modified.
        for hit in found.reversed() {
            guard let range = Range(hit.range, in: attributed),
                  let url = URL(string: "\(Self.scheme)://\(hit.citation)") else {
                continue
            }
            attributed[range].link = url
            attributed[range].underlineStyle = .single
        }
        return attributed
    }

    private static let scheme = "dai-citation"

    /// The citation index a link carries, if it is one of ours.
    static func index(of url: URL) -> Int? {
        guard url.scheme == scheme else { return nil }
        return Int(url.host() ?? "")
    }
}
