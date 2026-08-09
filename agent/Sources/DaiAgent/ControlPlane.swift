import AsyncHTTPClient
import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Client for the control plane, speaking `control-plane/openapi/dai.yaml`.
///
/// This is the third implementation of that schema, after the control plane
/// itself and the Python agent, which is the point of writing it first: a
/// mismatch surfaces between independent implementations rather than in
/// production.
///
/// Two properties this client is careful about.
///
/// **The local policy is a floor, not a suggestion.** The control plane serves a
/// policy table and the agent fetches it, but the agent carries its own and
/// applies whichever is more restrictive. A control plane that is compromised,
/// misconfigured, or simply newer must not be able to talk a machine into
/// running GPU work while someone is using it.
///
/// **Unreachable is not permission.** Every failure path leaves the agent doing
/// less work, never more.
public actor ControlPlane {
    public enum Failure: Error, CustomStringConvertible {
        case notEnrolled(String)
        case http(Int, String)
        case transport(String)
        case identity(String)

        public var description: String {
            switch self {
            case let .notEnrolled(m): return "not enrolled or not approved: \(m)"
            case let .http(c, m): return "HTTP \(c): \(m)"
            case let .transport(m): return "unreachable: \(m)"
            case let .identity(m): return "client identity: \(m)"
            }
        }
    }

    private let base: URL
    private let client: HTTPClient

    /// - Parameters:
    ///   - identity: the node's certificate and its Enclave key, for mTLS.
    ///   - serverCAPEM: the CA that signs the *control plane's* certificate. Not
    ///     the node CA, which signs agent identities and which a node never
    ///     needs. Pinning the wrong one fails every connection with a
    ///     certificate error that reads like a network problem.
    public init(base: URL, identity: NodeIdentity?, serverCAPEM: String?) throws {
        self.base = base

        var tls = TLSConfiguration.makeClientConfiguration()
        if let serverCAPEM {
            // Only the pinned CA is acceptable. Leaving the system anchors in
            // place would mean any publicly trusted certificate for this host
            // also works, which is not what pinning is for.
            tls.trustRoots = .certificates(
                try NIOSSLCertificate.fromPEMBytes(Array(serverCAPEM.utf8)))
        }
        if let identity {
            tls.certificateChain = try NIOSSLCertificate
                .fromPEMBytes(Array(identity.certificatePEM.utf8))
                .map { .certificate($0) }
            // The key itself is never handed over, only the ability to sign with
            // it. See EnclaveSigner for why this is not URLSession.
            tls.privateKey = .privateKey(
                NIOSSLPrivateKey(customPrivateKey: EnclaveSigner(key: identity.key)))
        }

        var config = HTTPClient.Configuration(tlsConfiguration: tls)
        // The reverse channel holds a request open, so the read timeout has to
        // outlast the server's long poll rather than cutting it short.
        config.timeout = .init(connect: .seconds(10), read: .seconds(300))
        // Explicitly the BSD sockets loop. AsyncHTTPClient defaults to
        // Network.framework on macOS, which refuses a client certificate chain
        // outright: "TLSConfiguration.certificateChain is not supported". The
        // custom signing key needs the NIOSSL path, so that default has to go.
        self.client = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
                                 configuration: config)
    }

    /// AsyncHTTPClient traps if it is deallocated while still running, so this
    /// is not optional politeness. A long-lived agent never calls it; a CLI
    /// command does, on the way out.
    public func shutdown() async {
        try? await client.shutdown()
    }

    // MARK: - Transport

    private func request(_ method: String, _ path: String, body: JSONValue? = nil,
                         query: [String: String] = [:],
                         headers: [String: String] = [:],
                         timeout: TimeInterval? = nil) async throws -> (Int, Data) {
        // Query parameters go through URLComponents rather than into the path.
        // appendingPathComponent percent-encodes "?" into %3F, so a path with a
        // query string in it becomes a single nonsense path segment. The server
        // answers 404, the caller's `try?` swallows it, and the agent polls
        // forever finding no work while the queue is full. That is exactly what
        // it did.
        var components = URLComponents(url: base.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            // Encoded explicitly, down to the reserved characters. URLComponents
            // leaves "," alone because RFC 3986 permits it in a query, but the
            // server's OpenAPI validator rejects any reserved character it finds
            // there: "Parameter 'kinds' must be url encoded".
            //
            // The effect was invisible in the worst way. A single kind has no
            // comma and worked; asking for two produced a 400 that the agent
            // swallowed, so a node sat in LOCKED with GPU work queued, asking
            // for it every five seconds, and never being told no.
            components.percentEncodedQueryItems = query.map {
                URLQueryItem(name: $0.key,
                             value: $0.value.addingPercentEncoding(
                                withAllowedCharacters: .daiQueryValue) ?? $0.value)
            }
        }
        var req = HTTPClientRequest(url: components.url!.absoluteString)
        req.method = .init(rawValue: method)
        req.headers.add(name: "content-type", value: "application/json")
        for (k, v) in headers { req.headers.add(name: k, value: v) }
        if let body { req.body = .bytes(ByteBuffer(data: try JSONEncoder().encode(body))) }

        do {
            let response = try await client.execute(
                req, timeout: .seconds(Int64(timeout ?? 60)))
            let code = Int(response.status.code)
            // Work units carry their payloads inline, so this ceiling is a real
            // constraint rather than a formality.
            let buffer = try await response.body.collect(upTo: 64 * 1024 * 1024)
            let data = Data(buffer: buffer)
            if code == 401 || code == 403 {
                throw Failure.notEnrolled(String(data: data, encoding: .utf8) ?? "")
            }
            guard (200..<300).contains(code) else {
                throw Failure.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            return (code, data)
        } catch let e as Failure {
            throw e
        } catch {
            throw Failure.transport(String(describing: error))
        }
    }

    /// Unauthenticated liveness check.
    ///
    /// Useful precisely because it needs no client certificate: if this works
    /// and an authenticated call does not, the fault is in the identity rather
    /// than the network.
    public func healthz() async throws -> String {
        let (_, data) = try await request("GET", "healthz")
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func json(_ data: Data) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object([:])
    }

    // MARK: - Enrollment

    public struct Enrollment: Sendable {
        public let nodeId: String
        public let enrollmentToken: String
    }

    /// Request enrollment. A join token grants nothing by itself: the node waits
    /// in `pending` until an admin approves it, so this is the start of the flow
    /// rather than the end.
    public func enroll(joinToken: String, hostname: String, chip: String,
                       machineId: String? = nil,
                       memoryGb: Double, metalWorkingSetGb: Double,
                       osVersion: String, csrPEM: String) async throws -> Enrollment {
        let (_, data) = try await request("POST", "agent/v1/enroll", body: .object([
            "joinToken": .string(joinToken), "hostname": .string(hostname),
            "chip": .string(chip), "memoryGb": .number(memoryGb),
            "metalWorkingSetGb": .number(metalWorkingSetGb),
            "osVersion": .string(osVersion), "csrPem": .string(csrPEM),
            // Ties this record to the hardware, so re-enrolling a machine
            // replaces its old record instead of adding a second one.
            "machineId": machineId.map(JSONValue.string) ?? .null,
        ]))
        let d = json(data)
        guard let id = d["nodeId"]?.stringValue, let token = d["enrollmentToken"]?.stringValue else {
            throw Failure.http(202, "enrollment response missing nodeId or token")
        }
        return Enrollment(nodeId: id, enrollmentToken: token)
    }

    public struct IssuedIdentity: Sendable {
        public let certPEM: String
        public let serverCAPEM: String?
    }

    /// Collect the certificate after approval. Returns nil while still pending.
    ///
    /// Cannot use mTLS: the whole point is that the node has no certificate yet,
    /// so the single-use enrollment token stands in.
    public func collectCertificate(nodeId: String,
                                   enrollmentToken: String) async throws -> IssuedIdentity? {
        let (code, data) = try await request("GET", "agent/v1/enroll/\(nodeId)",
                                             headers: ["x-enrollment-token": enrollmentToken])
        if code == 202 { return nil }
        let d = json(data)
        guard let cert = d["certPem"]?.stringValue else { return nil }
        return IssuedIdentity(certPEM: cert, serverCAPEM: d["serverCaPem"]?.stringValue)
    }

    // MARK: - Policy

    /// The served policy table, in the agent's shape.
    public func fetchPolicy() async throws -> [PresenceState: StatePolicy] {
        let (_, data) = try await request("GET", "agent/v1/policy")
        guard case let .object(table) = json(data) else { return [:] }
        var out: [PresenceState: StatePolicy] = [:]
        for (key, p) in table {
            guard let state = PresenceState(rawValue: key) else { continue }
            // Defaults here are the restrictive ones: a served policy missing a
            // field must not accidentally widen what the agent will do.
            out[state] = StatePolicy(
                gpu: { if case let .bool(b) = p["gpu"] { return b }; return false }(),
                ane: { if case let .bool(b) = p["ane"] { return b }; return false }(),
                qos: QoS(rawValue: p["qos"]?.stringValue ?? "background") ?? .background,
                dutyMax: { if case let .number(n) = p["dutyMax"] { return n }; return 0 }(),
                memFrac: { if case let .number(n) = p["memFrac"] { return n }; return 0 }(),
                maxCompletionTokens: p["maxCompletionTokens"]?.intValue ?? 256)
        }
        return out
    }

    // MARK: - Work

    public func heartbeat(state: PresenceState, onACPower: Bool?, thermalOK: Bool?,
                          userPaused: Bool = false,
                          capability: [String: Double] = [:],
                          residentModels: [String: Double] = [:]) async throws {
        var body: [String: JSONValue] = [
            "presenceState": .string(state.rawValue),
            // Replaced rather than merged: a model released on a yield is no
            // longer resident, and routing to a node that must reload it defeats
            // the point of tracking residency.
            "residentModels": .object(residentModels.mapValues { .number($0) }),
        ]
        // Always sent, including when false, so that resuming is reported as
        // positively as pausing. Omitting it would leave the control plane
        // holding a stale pause with no way to learn otherwise, and a fleet
        // view that under-reports capacity is a fleet view people stop reading.
        body["userPaused"] = .bool(userPaused)
        if let onACPower { body["onAcPower"] = .bool(onACPower) }
        if let thermalOK { body["thermalOk"] = .bool(thermalOK) }
        if !capability.isEmpty {
            // Observed from completed work, per workload class. The scheduler
            // needs a profile rather than a scalar: the same two machines
            // differed 7.5% on a 1.5B model and 26.3% on a 7B.
            body["capabilitySamples"] = .array(capability.map {
                .object(["workloadClass": .string($0.key), "itemsPerSecond": .number($0.value)])
            })
        }
        _ = try await request("POST", "agent/v1/heartbeat", body: .object(body))
    }

    public struct Lease: Sendable {
        public let unitId: String
        public let kind: WorkKind
        public let modelHash: String?
        public let items: [WorkItem]
    }

    /// Lease a unit of work, or learn why none was given.
    ///
    /// `kinds` is what the node may run *right now* under its presence policy,
    /// not what it is capable of. Without that distinction the agent fetches
    /// work it must immediately hand back.
    /// Why the last lease returned nothing.
    ///
    /// Kept because "the node is idle" and "the node is being refused work" look
    /// identical from outside, and the causes are unrelated. Discarding this was
    /// how a node sat asking for work it was allowed to do and getting none,
    /// with nothing anywhere saying so.
    public private(set) var lastLeaseReason: String?

    public func leaseWork(kinds: [WorkKind]) async throws -> Lease? {
        guard !kinds.isEmpty else { lastLeaseReason = "no kinds permitted"; return nil }
        let (_, data) = try await request(
            "GET", "agent/v1/work",
            query: ["kinds": kinds.map(\.rawValue).joined(separator: ",")])
        let d = json(data)
        if let reason = d["reason"]?.stringValue {
            lastLeaseReason = reason   // empty | none-of-these-kinds | node-paused
            return nil
        }
        if d["unitId"]?.stringValue == nil {
            // A response that is neither a lease nor a reason means the two ends
            // disagree about the schema, which is worth saying out loud.
            lastLeaseReason = "unrecognised response: "
                + (String(data: data, encoding: .utf8)?.prefix(120) ?? "")
            return nil
        }
        lastLeaseReason = nil
        guard let id = d["unitId"]?.stringValue,
              let kind = WorkKind(rawValue: d["kind"]?.stringValue ?? ""),
              case let .array(items)? = d["items"] else { return nil }
        return Lease(unitId: id, kind: kind,
                     modelHash: d["modelHash"]?.stringValue, items: items)
    }

    /// Report completed items and hand back what was not reached.
    ///
    /// Returning the remainder is what makes preemption cheap; discarding the
    /// unit would make a yield cost a whole batch. A 409 means the lease expired
    /// and another node already has the work, so losing this result is correct.
    @discardableResult
    public func report(unitId: String, completed: [WorkItem],
                       unfinished: [WorkItem], seconds: Double,
                       failed: Bool = false) async throws -> Int {
        let (_, data) = try await request("POST", "agent/v1/work/\(unitId)/result",
                                          body: .object([
            "completed": .array(completed), "unfinished": .array(unfinished),
            "seconds": .number(seconds), "failed": .bool(failed),
        ]))
        return json(data)["requeued"]?.intValue ?? 0
    }
}

/// Combine the agent's policy with the server's, taking the stricter of each.
///
/// Not a preference for one side. The server knows fleet-wide intent and may be
/// newer; the agent knows the machine and is the thing that will actually
/// disturb its owner. The intersection means neither a stale agent nor a
/// compromised control plane can widen what runs on someone's Mac, and
/// disagreement resolves toward less work rather than more.
public func mergePolicy(local: [PresenceState: StatePolicy],
                        served: [PresenceState: StatePolicy]) -> [PresenceState: StatePolicy] {
    guard !served.isEmpty else { return local }
    var out: [PresenceState: StatePolicy] = [:]
    for (state, lp) in local {
        guard let sp = served[state] else { out[state] = lp; continue }
        out[state] = StatePolicy(
            gpu: lp.gpu && sp.gpu,
            ane: lp.ane && sp.ane,
            // background is the more restrictive of the two.
            qos: (lp.qos == .background || sp.qos == .background) ? .background : .standard,
            dutyMax: min(lp.dutyMax, sp.dutyMax),
            memFrac: min(lp.memFrac, sp.memFrac),
            maxCompletionTokens: min(lp.maxCompletionTokens, sp.maxCompletionTokens))
    }
    return out
}

/// Presents the node's client certificate and pins the server CA.
///
/// Pinning rather than trusting the system store: a node that verifies nothing
/// accepts work from anything that can reach it on the network, and a work unit
/// tells a node what to execute.
/// The node's identity: the certificate the control plane issued, and the
/// Enclave key it was issued against.
///
/// The key is a handle rather than key material. Nothing here can export it,
/// which is the point.
public struct NodeIdentity: Sendable {
    public let certificatePEM: String
    public let key: EnclaveKey

    public init(certificatePEM: String, key: EnclaveKey) {
        self.certificatePEM = certificatePEM
        self.key = key
    }

    /// Load from the files enrollment wrote.
    public static func load(certificate: URL, enclaveKey: URL) throws -> NodeIdentity {
        NodeIdentity(certificatePEM: try String(contentsOf: certificate, encoding: .utf8),
                     key: try EnclaveKey.loadOrCreate(at: enclaveKey))
    }
}


extension CharacterSet {
    /// Unreserved characters only, per RFC 3986. Everything else in a query
    /// value gets percent-encoded, which is stricter than URL parsers require
    /// and exactly what a strict server-side validator expects.
    static let daiQueryValue = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
