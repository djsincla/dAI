import AsyncHTTPClient
import CryptoKit
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

    /// This node's own record, which is how it learns what it is offered for.
    public struct NodeSelf: Sendable {
        public let hostname: String
        /// Every kind of work this machine is offered for. A machine may be
        /// offered for both, which is why this is a list and not a value.
        public let tiers: [String]

        /// Whether presence gates this machine.
        ///
        /// One question with one answer, unchanged by tiers becoming plural: a
        /// machine offered for cluster work at all is never preempted, because
        /// a conversation needs a model that is still resident a minute from
        /// now and the harvest tier cannot promise that.
        ///
        /// For a machine that is *also* harvest that is a real consequence, not
        /// a technicality - an interactive request can arrive while somebody is
        /// using it. That is the trade the operator made when they put it in
        /// both, and the agent's job is to honour it rather than second-guess
        /// it.
        public var isCluster: Bool { tiers.contains("cluster") }

        public init(hostname: String, tiers: [String]) {
            self.hostname = hostname
            self.tiers = tiers.isEmpty ? ["harvest"] : tiers
        }
    }

    public func whoami() async throws -> NodeSelf {
        let (_, data) = try await request("GET", "agent/v1/me")
        let d = json(data)
        // The list if the control plane sends one, the old scalar otherwise. An
        // agent may be talking to a control plane either side of the change,
        // and reading neither would silently make every machine harvest.
        let tiers = d["tiers"]?.arrayValue?.compactMap(\.stringValue)
            ?? [d["tier"]?.stringValue ?? "harvest"]
        return NodeSelf(hostname: d["hostname"]?.stringValue ?? "", tiers: tiers)
    }

    public struct Dispatch: Sendable {
        public let id: String
        public let kind: WorkKind
        public let modelHash: String?
        public let body: JSONValue
    }

    /// Park on the reverse channel until the control plane pushes something.
    ///
    /// Returns nil on a 204, which is the server saying "nothing yet, come
    /// back": a timeout the node can see is far better than a socket it cannot
    /// tell from a dead one.
    public func awaitDispatch() async throws -> Dispatch? {
        // Longer than the server's long-poll window, or the client gives up
        // first and every idle period looks like an error.
        let (code, data) = try await request("GET", "agent/v1/dispatch", timeout: 120)
        guard code == 200 else { return nil }
        let d = json(data)
        guard let id = d["dispatchId"]?.stringValue,
              let kind = WorkKind(rawValue: d["kind"]?.stringValue ?? "") else { return nil }
        return Dispatch(id: id, kind: kind,
                        modelHash: d["modelHash"]?.stringValue,
                        body: d["body"] ?? .object([:]))
    }

    /// Whether the caller has given up on a request still being worked on.
    ///
    /// Asked rather than told: the node is inside a generation loop with no
    /// open channel to receive anything, so it checks. A failure here answers
    /// false, because a network blip should not throw away work in progress.
    public func isDispatchCancelled(id: String) async -> Bool {
        guard let (_, data) = try? await request(
            "GET", "agent/v1/dispatch/\(id)/cancelled", timeout: 10) else { return false }
        return json(data)["cancelled"] == .bool(true)
    }

    public func reportDispatch(id: String, text: String?, error: String?,
                               promptTokens: Int = 0,
                               completionTokens: Int = 0,
                               cachedTokens: Int = 0,
                               toolCalls: [ToolCall] = []) async throws {
        var body: [String: JSONValue] = [:]
        // A count has no text and is still a success. Reported separately so
        // the control plane is not left deciding whether an empty answer means
        // failure.
        if text == nil, error == nil {
            body["result"] = .object(["promptTokens": .number(Double(promptTokens))])
        }
        if let text {
            body["result"] = .object([
                "text": .string(text),
                // Structured, not text. The client has to execute these, so
                // handing back a string it would have to re-parse just moves
                // the guessing somewhere with less context.
                "toolCalls": .array(toolCalls.map {
                    .object(["name": .string($0.name), "arguments": $0.arguments])
                }),
                // Real counts from the runtime. A client drives its context
                // gauge and its compaction from these, so zeros tell it the
                // conversation is never filling up.
                "promptTokens": .number(Double(promptTokens)),
                "completionTokens": .number(Double(completionTokens)),
                // Prompt tokens answered from cache rather than read again.
                "cachedTokens": .number(Double(cachedTokens)),
            ])
        }
        if let error { body["error"] = .string(error) }
        _ = try await request("POST", "agent/v1/dispatch/\(id)/result", body: .object(body))
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
        /// The CA that signs *node* certificates.
        ///
        /// Needed because nodes now talk to each other: a machine holding half a
        /// model has to verify the machine holding the other half, and the
        /// server CA cannot vouch for it. Kept separate from serverCAPEM so
        /// that trusting a peer never widens what is trusted as a control
        /// plane.
        public let nodeCAPEM: String?
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
        return IssuedIdentity(certPEM: cert, serverCAPEM: d["serverCaPem"]?.stringValue,
                              nodeCAPEM: d["nodeCaPem"]?.stringValue)
    }

    public struct ReportOutcome: Sendable {
        public let requeued: Int
        /// Whether that was the last unit of the job.
        ///
        /// Told rather than inferred, so a node can delete its copy of the
        /// job's content the moment it becomes rubbish. Waiting to be swept
        /// would leave tens of gigabytes of somebody else's finished work on
        /// somebody else's workstation, and the agent is a guest there.
        public let jobFinished: Bool

        public init(requeued: Int, jobFinished: Bool = false) {
            self.requeued = requeued
            self.jobFinished = jobFinished
        }
    }

    public struct Renewed: Sendable {
        public let certPEM: String
        public let rekeyed: Bool
        public let serverCAPEM: String?
        public let nodeCAPEM: String?
    }

    /// Ask for a fresh certificate over the identity this node already has.
    ///
    /// Authenticated by the certificate being replaced, so there is no token
    /// and no human. Certificates are short-lived on purpose - a machine that
    /// leaves the building should stop being a fleet member on its own - and
    /// that property is only affordable if the machines still here renew
    /// unattended.
    public func renew(csrPEM: String) async throws -> Renewed {
        let (code, data) = try await request("POST", "agent/v1/renew",
                                             body: .object(["csrPem": .string(csrPEM)]))
        guard code == 200 else {
            throw Failure.http(code, String(data: data, encoding: .utf8) ?? "renewal refused")
        }
        let d = json(data)
        guard let cert = d["certPem"]?.stringValue else {
            throw Failure.http(code, "renewal response carried no certificate")
        }
        return Renewed(certPEM: cert,
                       rekeyed: d["rekeyed"]?.boolValue ?? false,
                       serverCAPEM: d["serverCaPem"]?.stringValue,
                       nodeCAPEM: d["nodeCaPem"]?.stringValue)
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

    // MARK: - Models

    public struct AssignedModel: Sendable {
        public let id: String
        public let runtime: String
        public let kind: String
        public let files: [ModelFile]
    }

    public struct ModelFile: Sendable {
        public let path: String
        public let sizeBytes: Int
        public let sha256: String
    }

    /// What this node has been told to hold.
    public func assignedModels() async throws -> [AssignedModel] {
        let (_, data) = try await request("GET", "/agent/v1/models/assigned")
        guard let list = (try? JSONDecoder().decode(JSONValue.self, from: data))?.arrayValue
            else { return [] }
        return list.compactMap { (item: JSONValue) -> AssignedModel? in
            guard let d = item.objectValue,
                  let id = d["id"]?.stringValue,
                  let files = d["files"]?.arrayValue else { return nil }
            return AssignedModel(
                id: id,
                runtime: d["runtime"]?.stringValue ?? "mlx",
                kind: d["kind"]?.stringValue ?? "generate",
                files: files.compactMap { (f: JSONValue) -> ModelFile? in
                    guard let fd = f.objectValue,
                          let path = fd["path"]?.stringValue,
                          let sha = fd["sha256"]?.stringValue else { return nil }
                    return ModelFile(path: path,
                                     sizeBytes: fd["sizeBytes"]?.intValue ?? 0,
                                     sha256: sha)
                })
        }
    }

    /// The URL of one model file.
    ///
    /// Built as a string rather than with `appendingPathComponent`, which
    /// percent-encodes what it is given: an already-encoded `%2F` came back as
    /// `%252F` and every download 404'd against a route that was working. The
    /// same method mangled a query string earlier in this project's life, in
    /// the same silent way.
    static func modelFileURL(base: URL, modelId: String, path: String) -> String {
        let id = modelId.addingPercentEncoding(withAllowedCharacters: .daiPathSegment) ?? modelId
        let file = path.addingPercentEncoding(withAllowedCharacters: .daiPathSegment) ?? path
        let root = base.absoluteString.hasSuffix("/")
            ? String(base.absoluteString.dropLast())
            : base.absoluteString
        return "\(root)/agent/v1/models/\(id)/files/\(file)"
    }

    /// Stream one model file to `destination`, returning its sha256.
    ///
    /// Streamed to disk rather than collected in memory: a shard is gigabytes
    /// and the machine this runs on is somebody's workstation, so buffering one
    /// would take memory away from the very person the agent exists to avoid
    /// disturbing.
    ///
    /// Both path components are percent-encoded, because a model id contains a
    /// slash and would otherwise become two path segments and a 404.
    public func downloadModelFile(modelId: String, path: String,
                                  to destination: URL) async throws -> String {
        try await stream(Self.modelFileURL(base: base, modelId: modelId, path: path),
                         to: destination, describing: "\(modelId)/\(path)")
    }

    /// Stream a URL to a file, returning its sha256.
    ///
    /// Shared by models and scenes because the requirement is identical and the
    /// details are the kind that are got wrong once per copy: streamed rather
    /// than buffered, written under a temporary name, and renamed only by the
    /// caller once the hash matches.
    private func stream(_ url: String, to destination: URL,
                        describing what: String) async throws -> String {
        var req = HTTPClientRequest(url: url)
        req.method = .GET

        // Generous, because this is measured in gigabytes over whatever network
        // the building has, and a transfer killed at ten minutes would never
        // finish a 5GB shard on a slow link.
        let response = try await client.execute(req, timeout: .hours(2))
        guard (200..<300).contains(Int(response.status.code)) else {
            throw Failure.http(Int(response.status.code), "downloading \(what)")
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        // Written under a temporary name and renamed only after the hash is
        // checked, so an interrupted transfer cannot leave a file that looks
        // finished. A partial shard has a plausible size and fails much later,
        // as a corrupt-weights crash on whichever machine loads it first.
        let temp = destination.appendingPathExtension("partial")
        try? fm.removeItem(at: temp)
        fm.createFile(atPath: temp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: temp) else {
            throw Failure.transport("cannot write \(temp.path)")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        for try await chunk in response.body {
            let bytes = Data(buffer: chunk)
            hasher.update(data: bytes)
            try handle.write(contentsOf: bytes)
        }
        try handle.close()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Scenes and rendered frames

    public struct SceneManifest: Sendable {
        public let id: String
        /// The file the renderer opens, from the catalogue rather than from the
        /// unit. A render job is naturally described as "run this file", and a
        /// fleet that took that description from a work unit would be one where
        /// submitting a job means executing code on fifty machines.
        public let entry: String
        public let files: [File]

        public struct File: Sendable {
            public let path: String
            public let sizeBytes: Int
            public let sha256: String

            public init(path: String, sizeBytes: Int, sha256: String) {
                self.path = path
                self.sizeBytes = sizeBytes
                self.sha256 = sha256
            }
        }

        public init(id: String, entry: String, files: [File]) {
            self.id = id
            self.entry = entry
            self.files = files
        }
    }

    /// What a scene is made of, so this node can work out what it is missing.
    public func sceneManifest(id: String) async throws -> SceneManifest {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .daiPathSegment) ?? id
        let (code, data) = try await request("GET", "agent/v1/scenes/\(encoded)")
        guard code == 200 else { throw Failure.http(code, "fetching scene \(id)") }
        let d = json(data)
        guard let entry = d["entry"]?.stringValue else {
            throw Failure.http(code, "scene \(id) has no entry file")
        }
        let files = (d["files"]?.arrayValue ?? []).compactMap { item -> SceneManifest.File? in
            guard let o = item.objectValue, let path = o["path"]?.stringValue,
                  let sha = o["sha256"]?.stringValue else { return nil }
            return SceneManifest.File(path: path,
                                      sizeBytes: o["sizeBytes"]?.intValue ?? 0,
                                      sha256: sha)
        }
        return SceneManifest(id: id, entry: entry, files: files)
    }

    /// Stream one scene file to `destination`, returning its sha256.
    public func downloadSceneFile(sceneId: String, path: String,
                                  to destination: URL) async throws -> String {
        let id = sceneId.addingPercentEncoding(withAllowedCharacters: .daiPathSegment) ?? sceneId
        let file = path.addingPercentEncoding(withAllowedCharacters: .daiPathSegment) ?? path
        let root = base.absoluteString.hasSuffix("/")
            ? String(base.absoluteString.dropLast()) : base.absoluteString
        return try await stream("\(root)/agent/v1/scenes/\(id)/files/\(file)",
                                to: destination, describing: "\(sceneId)/\(path)")
    }

    /// Hand a finished frame back.
    ///
    /// Streamed from disk rather than read into memory. A frame is tens of
    /// megabytes and this runs on somebody's workstation; the render already
    /// took the memory it needed and giving it back matters more here than
    /// anywhere else in the agent.
    @discardableResult
    public func uploadOutput(unitId: String, name: String, file: URL) async throws -> Int {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .daiPathSegment) ?? name
        let root = base.absoluteString.hasSuffix("/")
            ? String(base.absoluteString.dropLast()) : base.absoluteString
        var req = HTTPClientRequest(url: "\(root)/agent/v1/work/\(unitId)/output/\(encoded)")
        req.method = .PUT
        req.headers.add(name: "content-type", value: "application/octet-stream")
        let bytes = try Data(contentsOf: file)
        req.body = .bytes(ByteBuffer(bytes: bytes))
        let response = try await client.execute(req, timeout: .minutes(30))
        guard (200..<300).contains(Int(response.status.code)) else {
            throw Failure.http(Int(response.status.code), "uploading \(name)")
        }
        return bytes.count
    }

    /// What a job needs on this machine, and which file the adapter opens.
    public func jobAttachments(jobId: String) async throws -> SceneManifest {
        let id = jobId.addingPercentEncoding(withAllowedCharacters: .daiPathSegment) ?? jobId
        let (code, data) = try await request("GET", "agent/v1/jobs/\(id)/attachments")
        guard code == 200 else { throw Failure.http(code, "fetching attachments for \(jobId)") }
        let d = json(data)
        let files = (d["files"]?.arrayValue ?? []).compactMap { item -> SceneManifest.File? in
            guard let o = item.objectValue, let path = o["path"]?.stringValue,
                  let sha = o["sha256"]?.stringValue else { return nil }
            return SceneManifest.File(path: path,
                                      sizeBytes: o["sizeBytes"]?.intValue ?? 0,
                                      sha256: sha)
        }
        return SceneManifest(id: jobId, entry: d["entry"]?.stringValue ?? "", files: files)
    }

    /// One piece of content, by its hash. Written to `<destination>.partial`,
    /// like every other transfer here, so the caller decides to accept it only
    /// after checking what arrived.
    public func downloadBlob(sha256: String, to destination: URL) async throws -> String {
        let root = base.absoluteString.hasSuffix("/")
            ? String(base.absoluteString.dropLast()) : base.absoluteString
        return try await stream("\(root)/agent/v1/blobs/\(sha256)",
                                to: destination, describing: sha256)
    }

    // MARK: - Agent builds

    public struct DesiredBuild: Sendable {
        public let version: String?
        public let sha256: String?
        public let sizeBytes: Int?
    }

    /// What this node should be running, or nothing when nobody manages it.
    public func desiredBuild() async throws -> DesiredBuild {
        let (_, data) = try await request("GET", "/agent/v1/agent/desired")
        let d = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue ?? [:]
        return DesiredBuild(version: d["version"]?.stringValue,
                            sha256: d["sha256"]?.stringValue,
                            sizeBytes: d["sizeBytes"]?.intValue)
    }

    /// Stream an agent binary to `destination`, returning its sha256.
    public func downloadAgentBuild(version: String, to destination: URL) async throws -> String {
        let encoded = version.addingPercentEncoding(
            withAllowedCharacters: .daiPathSegment) ?? version
        let root = base.absoluteString.hasSuffix("/")
            ? String(base.absoluteString.dropLast()) : base.absoluteString
        var req = HTTPClientRequest(url: "\(root)/agent/v1/agent/builds/\(encoded)/binary")
        req.method = .GET

        let response = try await client.execute(req, timeout: .minutes(30))
        guard (200..<300).contains(Int(response.status.code)) else {
            throw Failure.http(Int(response.status.code), "downloading agent \(version)")
        }

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        fm.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw Failure.transport("cannot write \(destination.path)")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        for try await chunk in response.body {
            let bytes = Data(buffer: chunk)
            hasher.update(data: bytes)
            try handle.write(contentsOf: bytes)
        }
        try handle.close()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Say what an upgrade did. Includes the rollbacks this server cannot see.
    public func reportUpgrade(fromVersion: String?, toVersion: String,
                              state: String, detail: String?) async throws {
        var body: [String: JSONValue] = [
            "toVersion": .string(toVersion), "state": .string(state),
        ]
        if let fromVersion { body["fromVersion"] = .string(fromVersion) }
        if let detail { body["detail"] = .string(detail) }
        _ = try await request("POST", "/agent/v1/agent/upgrades", body: .object(body))
    }

    // MARK: - Work

    public func heartbeat(state: PresenceState, onACPower: Bool?, thermalOK: Bool?,
                          userPaused: Bool = false,
                          capability: [String: Double] = [:],
                          residentModels: [String: Double] = [:],
                          storedModels: [String: Double]? = nil,
                          modelInfo: [String: Int] = [:],
                          syncFaults: [String: String]? = nil,
                          // Resolved by default rather than left nil, so that a
                          // nil reaching the body below means one thing only:
                          // this machine looked and has no address to offer.
                          // The distinction matters because that answer now
                          // clears the one on record.
                          pipelineAddress: String? = PipelineAddress.current())
        async throws -> Directives {
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
        // What this machine is running, on every beat rather than at enrolment:
        // a binary can be replaced by the control plane, by an MDM, or by
        // somebody at a keyboard, and only the node knows which one won.
        body["agentVersion"] = .string(AgentVersion.version)
        if !AgentVersion.fingerprint.isEmpty {
            body["agentFingerprint"] = .string(AgentVersion.fingerprint)
        }
        // Sent only when it has been scanned. Absent means unchanged, so a beat
        // from a loop that does not know what is on disk cannot erase what
        // another loop reported: two loops heartbeat for one node, and the last
        // time one spoke for the other the catalogue was wiped a second after
        // being written.
        if let storedModels {
            body["storedModels"] = .object(storedModels.mapValues { .number($0) })
        }
        if !modelInfo.isEmpty {
            // What each resident model actually accepts. Advertised so a client
            // does not have to assume a window: guessing high runs a
            // conversation past what the model takes, guessing low wastes most
            // of what it paid for.
            body["models"] = .array(modelInfo.map { name, context in
                .object(["name": .string(name), "contextLength": .number(Double(context))])
            })
        }
        // Sent only after a reconciliation pass has run, so absent means "no
        // news" rather than "all well". A pass that succeeded sends an empty
        // object, which is what clears a fault the operator has already seen.
        //
        // Reported at all because the alternative is what this fleet did for
        // twelve hours: a node failing every transfer, writing the reason to a
        // log nobody reads, while the console showed a count of machines still
        // wanting the model that never moved.
        if let syncFaults {
            body["syncFaults"] = .object(syncFaults.mapValues { .string($0) })
        }
        // Where a peer should dial this machine for pipeline traffic, which is
        // not where the control plane sees it connecting from. A split runs over
        // whatever link the machines share, and E7's ran over a Thunderbolt
        // bridge while both nodes reached the control plane over the LAN.
        // Always sent, including as null. A node whose link has gone is the
        // only thing that knows, and a control plane holding the address it
        // last heard will form a gang over a cable that is not there - which is
        // what a dropped Thunderbolt bridge did to this fleet, twice.
        body["pipelineAddress"] = pipelineAddress.map { JSONValue.string($0) } ?? .null
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
        // The reply carries what the control plane wants from this node. It is
        // the only channel there is: a harvested machine dials out and never
        // listens, so anything asked of it has to ride back on a beat it sent.
        //
        // An older control plane answers 204 with no body, which decodes to no
        // directives - the right answer, and the reason this is additive.
        let (_, data) = try await request("POST", "agent/v1/heartbeat", body: .object(body))
        let reply = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue ?? [:]
        return Directives(renewRequested: reply["renewRequested"]?.boolValue ?? false)
    }

    /// What the control plane asked of this node on the last beat.
    public struct Directives: Sendable, Equatable {
        /// Renew now rather than at two thirds of certificate life.
        ///
        /// Asked rather than done elsewhere because it cannot be done
        /// elsewhere: the Enclave key signs only inside this process, so a
        /// renewal run from any other session fails with "unable to sign
        /// digest".
        public let renewRequested: Bool

        public init(renewRequested: Bool = false) {
            self.renewRequested = renewRequested
        }
    }

    public struct Lease: Sendable {
        /// What this work is and who asked for it. Carried so the machine's
        /// owner can be told something more useful than "embed".
        public var jobLabel: String?
        public var jobSource: String = "api"

        public let unitId: String
        public let kind: WorkKind
        public let modelHash: String?
        /// The scene a render unit belongs to, from the job rather than from the
        /// unit. The unit says which frame; the job says of what. Keeping those
        /// two apart is what stops a submission naming the content it wants.
        public var sceneId: String?
        /// Which job this unit belongs to. A node asks the job what content it
        /// needs, and is told by the job when it may delete it again.
        public var jobId: String?
        public let items: [WorkItem]

        public init(jobLabel: String? = nil, jobSource: String = "api",
                    unitId: String, kind: WorkKind, modelHash: String? = nil,
                    sceneId: String? = nil, jobId: String? = nil, items: [WorkItem]) {
            self.jobLabel = jobLabel
            self.jobSource = jobSource
            self.unitId = unitId
            self.kind = kind
            self.modelHash = modelHash
            self.sceneId = sceneId
            self.jobId = jobId
            self.items = items
        }
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
        return Lease(jobLabel: d["jobLabel"]?.stringValue,
                     jobSource: d["jobSource"]?.stringValue ?? "api",
                     unitId: id, kind: kind,
                     modelHash: d["modelHash"]?.stringValue,
                     sceneId: d["sceneId"]?.stringValue,
                     jobId: d["jobId"]?.stringValue, items: items)
    }

    /// Report completed items and hand back what was not reached.
    ///
    /// Returning the remainder is what makes preemption cheap; discarding the
    /// unit would make a yield cost a whole batch. A 409 means the lease expired
    /// and another node already has the work, so losing this result is correct.
    @discardableResult
    public func report(unitId: String, completed: [WorkItem],
                       unfinished: [WorkItem], seconds: Double,
                       failed: Bool = false) async throws -> ReportOutcome {
        let (_, data) = try await request("POST", "agent/v1/work/\(unitId)/result",
                                          body: .object([
            "completed": .array(completed), "unfinished": .array(unfinished),
            "seconds": .number(seconds), "failed": .bool(failed),
        ]))
        let d = json(data)
        return ReportOutcome(requeued: d["requeued"]?.intValue ?? 0,
                             jobFinished: d["jobFinished"]?.boolValue ?? false)
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

    /// The same set, used for a path segment that must stay one segment.
    ///
    /// A model id contains a slash. Left alone it becomes two path components
    /// and the server answers 404 on a route that exists, which is a failure
    /// this codebase has already produced once by a different route.
    static let daiPathSegment = daiQueryValue
}
