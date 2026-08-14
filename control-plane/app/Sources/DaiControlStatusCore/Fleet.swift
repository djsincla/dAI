import Foundation

/// The fleet, read out of the Prometheus text the control plane already serves.
///
/// No new endpoint. `/monitor/v1/metrics` exists to be scraped and this is a
/// scraper, so inventing a JSON shape for one app would mean two contracts to
/// keep in step for the same numbers.
///
/// It may legitimately be refused. The monitoring surface is address-restricted
/// and loopback is not in the range by default, so an app on the control plane's
/// own machine can get a 403 from an endpoint six inches away. That is a
/// configuration answer and not a fault, and the window says so rather than
/// showing a fleet of zero - which would read as "every machine is gone".
public struct Fleet: Equatable, Sendable {
    public let version: String?
    public let nodes: Int
    public let working: Int

    public init(version: String?, nodes: Int, working: Int) {
        self.version = version
        self.nodes = nodes
        self.working = working
    }

    /// Parse the exposition format, ignoring everything not asked for.
    ///
    /// Written against the shape rather than the exact metric names in use, so a
    /// metric added or renamed on the server does not need a matching release of
    /// this app to avoid crashing it. Anything unrecognised is skipped.
    public static func parse(_ text: String) -> Fleet {
        var version: String?
        var nodes = 0
        var working = 0

        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }

            if line.hasPrefix("dai_build_info"), let v = label(line, "version") {
                version = v
                continue
            }
            guard let value = value(line) else { continue }

            if line.hasPrefix("dai_nodes") {
                nodes += Int(value)
                if label(line, "state") == "working" { working += Int(value) }
            }
        }
        return Fleet(version: version, nodes: nodes, working: working)
    }

    /// The value is whatever follows the last space on the line.
    private static func value(_ line: String) -> Double? {
        guard let sep = line.lastIndex(of: " ") else { return nil }
        return Double(line[line.index(after: sep)...])
    }

    /// Pull one label out of `name{a="1",b="2"} 3`.
    ///
    /// Values are quoted by the exposition format, which is what makes this safe
    /// to do without a full parser: a comma inside a label value cannot be
    /// confused with the separator, because the closing quote comes first.
    private static func label(_ line: String, _ want: String) -> String? {
        guard let open = line.firstIndex(of: "{"),
              let close = line.firstIndex(of: "}"), open < close
        else { return nil }
        var rest = line[line.index(after: open)..<close]
        while !rest.isEmpty {
            guard let eq = rest.firstIndex(of: "=") else { return nil }
            let key = rest[rest.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            var i = rest.index(after: eq)
            guard i < rest.endIndex, rest[i] == "\"" else { return nil }
            i = rest.index(after: i)
            guard let end = rest[i...].firstIndex(of: "\"") else { return nil }
            if key == want { return String(rest[i..<end]) }
            let next = rest.index(after: end)
            rest = next < rest.endIndex ? rest[rest.index(after: next)...] : rest[rest.endIndex...]
        }
        return nil
    }
}
