import Foundation

/// Reading a chunk's locator back into the place it points at.
///
/// A locator is a file name and any number of fragments:
///
///     vmware-cloud-foundation-9-1.pdf#page=2#part=3
///     statutes.md#part=2
///     sales.xlsx#row=417
///
/// **The fragments accumulate, and that is what the first reader of them got
/// wrong.** Taking the last one and checking it says `page=` works for
/// `#page=1` and fails for `#page=2#part=3`, so every chunk of a page that
/// produced more than one chunk reported no page at all. In an 8,894 page
/// manual almost every page produces several, so almost every citation opened
/// the document at page one, which for a document that size is the same as not
/// opening it.
///
/// Parsed here rather than in each view, because two views were parsing it
/// slightly differently and both were wrong in the same way.
public enum Locator {

    /// The file, without any fragments and without its directories.
    public static func fileName(of locator: String) -> String {
        let path = String(locator.split(separator: "#", maxSplits: 1,
                                        omittingEmptySubsequences: false).first ?? "")
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    /// The page, one based as a reader sees it, if this locator names one.
    public static func page(of locator: String) -> Int? {
        value(of: "page", in: locator)
    }

    /// Which chunk of that page or document this was, if it was one of several.
    public static func part(of locator: String) -> Int? {
        value(of: "part", in: locator)
    }

    /// Which row of a table, if this locator names one.
    public static func row(of locator: String) -> Int? {
        value(of: "row", in: locator)
    }

    /// The value of one named fragment.
    ///
    /// Every fragment is examined rather than only the last, and the first one
    /// with this name wins. A locator carries its coarsest coordinate first, so
    /// first is the right one when a malformed locator repeats a name.
    static func value(of name: String, in locator: String) -> Int? {
        let prefix = name + "="
        for fragment in locator.split(separator: "#").dropFirst()
        where fragment.hasPrefix(prefix) {
            if let number = Int(fragment.dropFirst(prefix.count)) { return number }
        }
        return nil
    }
}
