import Foundation

/// What the agent is doing, published for the person whose machine it is.
///
/// The daemon runs as a service account in session 0 and the menu bar app runs
/// as the logged-in user, so they cannot share memory, a socket the user could
/// reach without privilege, or anything else convenient. A file under
/// `/Users/Shared` is the one place both can meet without either needing rights
/// the other should not have.
///
/// Written on every loop, which is cheap and means the menu bar never shows
/// something stale enough to be a lie. `updated` is included precisely so the UI
/// can tell the difference between "idle" and "the daemon died", which look
/// identical otherwise and mean opposite things.
public struct AgentStatus: Codable, Sendable, Equatable {
    public var updated: Date
    public var presenceState: String
    /// Paused here, by the person at the machine.
    public var paused: Bool
    public var pauseReason: String?
    /// Paused by an operator, which the agent only learns by being refused
    /// work. Kept separate from `paused` because they are different facts with
    /// different remedies: one the person at the machine can undo and the other
    /// they cannot, and showing them the same way would be misleading in both
    /// directions.
    public var pausedByFleet: Bool
    /// What this machine is permitted to run right now, which is not what it is
    /// capable of.
    public var permitted: [String]
    public var activity: String
    /// What the current work actually is, and where it came from.
    ///
    /// "embed" describes a compute unit, not a purpose. Somebody looking at
    /// their own machine deserves to know whether it is indexing the document
    /// archive or running somebody's load test, and those should not look the
    /// same.
    public var jobLabel: String?
    public var jobSource: String?
    public var controlPlaneReachable: Bool

    /// Cumulative, and the point of the whole panel.
    ///
    /// A contribution counter is cheap to build and does most of the political
    /// work of the product: it reframes "IT took my machine" as "I contribute to
    /// the farm". People who can see what they gave are far slower to resent it.
    public var itemsCompleted: Int
    public var unitsCompleted: Int
    public var yields: Int
    public var residentGb: Double
    public var lastYield: Date?
    /// Interactive requests answered, which is a different kind of
    /// contribution from batch items and worth showing as one.
    public var requestsAnswered: Int = 0

    public init(updated: Date = Date(), presenceState: String = "unknown",
                paused: Bool = false, pauseReason: String? = nil,
                pausedByFleet: Bool = false,
                permitted: [String] = [], activity: String = "starting",
                jobLabel: String? = nil, jobSource: String? = nil,
                controlPlaneReachable: Bool = false,
                itemsCompleted: Int = 0, unitsCompleted: Int = 0, yields: Int = 0,
                residentGb: Double = 0, lastYield: Date? = nil,
                requestsAnswered: Int = 0) {
        self.updated = updated
        self.presenceState = presenceState
        self.paused = paused
        self.pauseReason = pauseReason
        self.pausedByFleet = pausedByFleet
        self.permitted = permitted
        self.activity = activity
        self.jobLabel = jobLabel
        self.jobSource = jobSource
        self.controlPlaneReachable = controlPlaneReachable
        self.itemsCompleted = itemsCompleted
        self.unitsCompleted = unitsCompleted
        self.yields = yields
        self.residentGb = residentGb
        self.lastYield = lastYield
        self.requestsAnswered = requestsAnswered
    }

    public static let defaultPath = "/Users/Shared/.dai-status.json"

    /// Considered current if written recently. The daemon publishes on every
    /// poll, and the slowest poll interval is 5s, so anything older than a
    /// minute means it has stopped rather than that nothing is happening.
    public var isFresh: Bool { Date().timeIntervalSince(updated) < 60 }

    public static func read(path: String = defaultPath) -> AgentStatus? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentStatus.self, from: data)
    }

    public func write(path: String = defaultPath) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(self) else { return }
        let url = URL(fileURLWithPath: path)
        // Atomic, because the reader polls and a half-written file would show up
        // as the agent having crashed.
        try? data.write(to: url, options: .atomic)
        // World-readable on purpose: written by the service account, read by
        // whoever is logged in.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: path)
    }
}
