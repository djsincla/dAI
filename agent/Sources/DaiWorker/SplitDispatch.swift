import DaiAgent
import Foundation

/// A request to be one rank of a split model.
///
/// The control plane admits every rank of a gang at once and tells each machine
/// the same three things: which rank it is, how many there are, and where the
/// listener can be reached. Nothing else has to be agreed, and nothing is
/// inferred from rank number - a machine is told to listen or to dial rather
/// than working it out, because that kind of implicit agreement survives right
/// up until somebody renumbers the ranks.
public struct SplitDispatch: Sendable, Equatable {
    public enum Role: String, Sendable {
        /// Holds the last layers and the output head, and waits to be dialled.
        case listen
        /// Holds earlier layers and dials the listener.
        case dial
    }

    public let rank: Int
    public let size: Int
    public let role: Role
    public let port: Int
    /// Where to dial. Nil for the rank that is being dialled.
    public let peer: String?
    public let model: String

    /// Read a dispatch body, or nil when this is an ordinary single-machine
    /// request.
    ///
    /// Every field is required rather than defaulted. A split that starts with
    /// half a plan is a pipeline that hangs, and a default here would turn a
    /// control plane sending the wrong shape into a machine waiting quietly for
    /// a peer that was never told to come.
    public init?(body: JSONValue) {
        guard let split = body["split"]?.objectValue,
              let rank = split["rank"]?.intValue,
              let size = split["size"]?.intValue,
              let roleName = split["role"]?.stringValue,
              let role = Role(rawValue: roleName),
              let port = split["port"]?.intValue,
              let model = split["model"]?.stringValue
        else { return nil }

        // A dialer with nowhere to dial cannot be started, and saying so here
        // is the difference between a clear failure and a stalled gang.
        let peer = split["peer"]?.stringValue
        if role == .dial && (peer == nil || peer!.isEmpty) { return nil }

        self.rank = rank
        self.size = size
        self.role = role
        self.port = port
        self.peer = peer
        self.model = model
    }

    /// Only for tests and for the by-hand path.
    public init(rank: Int, size: Int, role: Role, port: Int, peer: String?, model: String) {
        self.rank = rank
        self.size = size
        self.role = role
        self.port = port
        self.peer = peer
        self.model = model
    }
}
