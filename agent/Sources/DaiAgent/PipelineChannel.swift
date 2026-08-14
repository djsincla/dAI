import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// A direct link between two machines running halves of one model.
///
/// Deliberately not routed through the control plane. A hidden state crosses
/// this link once per token, so every hop is added to every token a person is
/// waiting on: a relay would put a third machine, and a second network trip, in
/// the middle of the tightest loop in the system.
///
/// Mutually authenticated with the same certificates the fleet already issues,
/// in both directions. A machine will run whatever arrives here through the
/// second half of a model and return the result, so the question of who is
/// allowed to send is not a detail.
///
/// One connection, one peer, and no reconnection. If the link drops the token
/// in flight is lost and the job is over, which is the honest behaviour: a
/// pipeline that silently reconnected mid-sequence would resume with a key-value
/// cache that no longer matches the conversation, and produce fluent nonsense
/// rather than an error.
public actor PipelineChannel {
    public enum Failure: Error, CustomStringConvertible {
        case notConnected
        case peerClosed
        case handshakeTimedOut
        case transport(String)

        public var description: String {
            switch self {
            case .notConnected: return "no peer is connected"
            case .peerClosed: return "the other machine closed the link"
            case .handshakeTimedOut: return "the other machine did not connect in time"
            case let .transport(m): return m
            }
        }
    }

    private let group: EventLoopGroup
    private let ownsGroup: Bool
    /// Resolved when a peer has connected, or when the wait ran out.
    ///
    /// A future rather than an optional because binding and accepting are
    /// separate moments: the port has to be known before anybody can connect to
    /// it, so returning it only after a peer arrived was a deadlock written into
    /// the signature.
    private var connected: EventLoopFuture<Channel>?
    /// The same wait, still writable, so closing can end it.
    ///
    /// A listener whose peer never arrived would otherwise hold `close()` for
    /// the whole accept timeout - a minute, during which the port it is trying
    /// to give back is still bound and the next split on this machine cannot
    /// listen at all.
    private var accepting: EventLoopPromise<Channel>?
    private var bound: Channel?
    private var inbox: FrameInbox
    /// Where this link says what happened to it.
    ///
    /// Silent until a gang failed on real hardware and left nothing to read: one
    /// rank waited its full two minutes for a hidden state and the other's first
    /// write was still queued behind a handshake that never finished, and
    /// between them they logged that they had connected and nothing else. A
    /// transport that cannot say "the peer's certificate was refused" turns a
    /// one-line answer into an afternoon.
    private let log: @Sendable (String) -> Void
    /// How long two machines have to agree to talk before the link is given up
    /// on. Injectable so a test does not have to wait it out.
    private let handshakeDeadline: TimeAmount

    /// `group` is injectable so a test can run both ends in one process, and so
    /// the agent can share the loop group it already has rather than starting
    /// threads for a link that is idle most of the time.
    public init(group: EventLoopGroup? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in },
                handshakeDeadline: TimeAmount = .seconds(10)) {
        self.log = log
        self.handshakeDeadline = handshakeDeadline
        if let group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
        self.inbox = FrameInbox()
    }

    // MARK: - Connecting

    /// Wait for the other half to connect.
    ///
    /// The machine holding the later layers listens, because it is the one that
    /// produces the token and therefore the one a scheduler addresses.
    public func listen(port: Int, identity: NodeIdentity, peerCAPEM: String,
                       timeout: TimeInterval = 60) async throws -> Int {
        try await listen(port: port,
                         tls: Self.serverContext(identity: identity, peerCAPEM: peerCAPEM),
                         timeout: timeout)
    }

    /// Listen with a context somebody else built.
    ///
    /// Separated so the socket path can be tested. The identity-based version
    /// above signs through the Secure Enclave, and an Enclave key cannot be
    /// created in a test process, so without this seam the only tested part
    /// would be the codec while the actual connection went unexercised.
    public func listen(port: Int, tls: NIOSSLContext,
                       timeout: TimeInterval = 60) async throws -> Int {
        let accepted = group.next().makePromise(of: Channel.self)
        let inbox = self.inbox
        let deadline = handshakeDeadline

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 1)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { [log, deadline] ch in
                do {
                    log("pipeline: a peer connected from "
                        + "\(ch.remoteAddress.map(String.init(describing:)) ?? "an unknown address")")
                    let ssl = try NIOSSLServerHandler(context: tls)
                    return ch.pipeline.addHandler(ssl).flatMap {
                        ch.pipeline.addHandler(HandshakeWatcher(log: log, deadline: deadline))
                    }.flatMap {
                        ch.pipeline.addHandler(FrameHandler(inbox: inbox))
                    }.map {
                        accepted.succeed(ch)
                    }
                } catch {
                    return ch.eventLoop.makeFailedFuture(error)
                }
            }

        let server = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
        self.bound = server
        self.accepting = accepted

        // A peer that never arrives must not leave a job holding a machine open
        // indefinitely.
        group.next().scheduleTask(in: .seconds(Int64(timeout))) {
            accepted.fail(Failure.handshakeTimedOut)
        }
        self.connected = accepted.futureResult
        // Returned as soon as the socket is bound. Port 0 means the kernel
        // chose, and the caller needs to know which one before the other machine
        // can be told where to connect.
        return server.localAddress?.port ?? port
    }

    /// The name to offer in SNI, or nil when there is no name to offer.
    ///
    /// Anything that parses as an IPv4 or IPv6 address is not a name. Kept as a
    /// separate function so it can be tested without a socket.
    public static func sniName(for serverName: String) -> String? {
        if serverName.isEmpty { return nil }
        if let _ = try? SocketAddress(ipAddress: serverName, port: 0) { return nil }
        return serverName
    }

    /// Connect to the machine holding the later layers.
    public func connect(host: String, port: Int, identity: NodeIdentity,
                        peerCAPEM: String, serverName: String) async throws {
        try await connect(host: host, port: port,
                          tls: Self.clientContext(identity: identity, peerCAPEM: peerCAPEM),
                          serverName: serverName)
    }

    /// How long to wait before the nth attempt at dialling a peer.
    ///
    /// A pure function of the attempt so the schedule can be read and tested
    /// without waiting for it.
    ///
    /// Doubling from a fifth of a second and capped at two, because the two
    /// cases it separates have very different durations. A rank that has not
    /// finished binding its socket is milliseconds away; a rank that is never
    /// coming is not coming at all. A fixed short interval hammers the second
    /// case, and a fixed long one makes the first feel broken.
    public static func backoff(attempt: Int) -> TimeInterval {
        min(2.0, 0.2 * pow(2.0, Double(max(0, attempt))))
    }

    /// Dial a peer that may not be listening yet.
    ///
    /// Ranks find each other by dialling, and the dispatches that start them go
    /// out at the same time - so the listener is frequently not up when the
    /// first attempt arrives. That is ordinary and not a failure.
    ///
    /// Retrying here rather than coordinating through the control plane is
    /// deliberate. A handshake would mean rank 0 reporting that it is listening
    /// and the control plane then releasing rank 1, which puts the control plane
    /// in the middle of every split and adds a round trip to a path that is
    /// already latency-sensitive. A dial that keeps trying needs nobody, and the
    /// two cases it has to tell apart - not up yet, never coming - are
    /// distinguishable by giving up after a bounded time.
    ///
    /// `deadline` is that bound. Past it the peer is treated as absent, which is
    /// what the caller wants to hear: a gang that cannot form should fail loudly
    /// rather than wait, because every other rank is holding memory meanwhile.
    public func connectWithRetry(
        host: String, port: Int, identity: NodeIdentity, peerCAPEM: String,
        serverName: String, deadline: TimeInterval = 30,
    ) async throws {
        try await connectWithRetry(
            host: host, port: port,
            tls: Self.clientContext(identity: identity, peerCAPEM: peerCAPEM),
            serverName: serverName, deadline: deadline)
    }

    /// Retry against a context somebody else built.
    ///
    /// The same seam the plain `connect` has, and for the same reason: an
    /// Enclave key cannot be created in a test process, so without this the
    /// schedule would be untestable and only the arithmetic would be checked.
    public func connectWithRetry(
        host: String, port: Int, tls: NIOSSLContext,
        serverName: String, deadline: TimeInterval = 30,
        sleep: @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
    ) async throws {
        let started = Date()
        var attempt = 0
        while true {
            do {
                try await connect(host: host, port: port, tls: tls, serverName: serverName)
                return
            } catch {
                let waited = Date().timeIntervalSince(started)
                let next = Self.backoff(attempt: attempt)
                // Checked against the deadline before sleeping, so the last
                // thing that happens is an attempt rather than a wait.
                guard waited + next < deadline else { throw error }
                try await sleep(next)
                attempt += 1
            }
        }
    }

    public func connect(host: String, port: Int, tls: NIOSSLContext,
                        serverName: String) async throws {
        let inbox = self.inbox
        let deadline = handshakeDeadline

        let channel = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { [log, deadline] ch in
                do {
                    // SNI is a hostname field and TLS forbids putting an
                    // address in it, so a peer reached by address is offered no
                    // server name at all. That costs nothing here: the peer is
                    // trusted because it presents a certificate signed by the
                    // fleet CA, not because of what it is called, and the name
                    // is not checked either way.
                    let ssl = try NIOSSLClientHandler(
                        context: tls, serverHostname: Self.sniName(for: serverName))
                    return ch.pipeline.addHandler(ssl).flatMap {
                        ch.pipeline.addHandler(HandshakeWatcher(log: log, deadline: deadline))
                    }.flatMap {
                        ch.pipeline.addHandler(FrameHandler(inbox: inbox))
                    }
                } catch {
                    return ch.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: host, port: port).get()
        self.connected = channel.eventLoop.makeSucceededFuture(channel)
    }

    // MARK: - Moving tensors

    /// The connected channel, waiting for the peer if it has not arrived yet.
    private func active() async throws -> Channel {
        guard let connected else { throw Failure.notConnected }
        let channel = try await connected.get()
        guard channel.isActive else { throw Failure.peerClosed }
        return channel
    }

    public func send(_ frame: TensorFrame) async throws {
        let channel = try await active()
        var buffer = channel.allocator.buffer(capacity: 0)
        buffer.writeBytes(TensorCodec.encode(frame))
        try await channel.writeAndFlush(buffer).get()
    }

    /// The next tensor from the other machine.
    ///
    /// Waits rather than polling. A pipeline step has nothing else to do until
    /// the hidden state arrives, and a spin loop here would burn a core on the
    /// machine that is meant to be being polite.
    public func receive() async throws -> TensorFrame {
        try await inbox.next()
    }

    public func close() async {
        // Ended rather than waited out. Succeeding does nothing if a peer
        // already arrived, and if none did this is the difference between
        // giving the port back now and giving it back in a minute.
        accepting?.fail(Failure.peerClosed)
        accepting = nil
        if let connected, let channel = try? await connected.get() {
            try? await channel.close().get()
        }
        try? await bound?.close().get()
        connected = nil
        bound = nil
        await inbox.finish()
        if ownsGroup { try? await group.shutdownGracefully() }
    }

    // MARK: - TLS

    /// The same identity the agent already uses to reach the control plane: a
    /// certificate on disk and a key that never leaves the Secure Enclave, so
    /// signing happens through a custom key rather than by handing bytes over.
    private static func chain(_ identity: NodeIdentity) throws -> [NIOSSLCertificateSource] {
        try NIOSSLCertificate.fromPEMBytes(Array(identity.certificatePEM.utf8))
            .map { .certificate($0) }
    }

    private static func key(_ identity: NodeIdentity) -> NIOSSLPrivateKeySource {
        .privateKey(NIOSSLPrivateKey(customPrivateKey: EnclaveSigner(key: identity.key)))
    }

    private static func serverContext(identity: NodeIdentity,
                                      peerCAPEM: String) throws -> NIOSSLContext {
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: try chain(identity), privateKey: key(identity))
        // Verified in both directions. A machine that will run a model on
        // whatever arrives has to know the sender is a fleet member, not merely
        // that something connected. Only the fleet CA is acceptable; leaving the
        // system anchors in place would mean any publicly trusted certificate
        // also works, which is not what this is for.
        config.certificateVerification = .noHostnameVerification
        config.trustRoots = .certificates(
            try NIOSSLCertificate.fromPEMBytes(Array(peerCAPEM.utf8)))
        return try NIOSSLContext(configuration: config)
    }

    private static func clientContext(identity: NodeIdentity,
                                      peerCAPEM: String) throws -> NIOSSLContext {
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateChain = try chain(identity)
        config.privateKey = key(identity)
        // The certificate has to be signed by the fleet CA; it does not have to
        // match a hostname. A node certificate carries a node id as its subject
        // and machines are reached by whatever address they happen to have, so
        // full verification would reject every genuine peer.
        config.certificateVerification = .noHostnameVerification
        config.trustRoots = .certificates(
            try NIOSSLCertificate.fromPEMBytes(Array(peerCAPEM.utf8)))
        return try NIOSSLContext(configuration: config)
    }
}

/// Frames that have arrived, and whoever is waiting for one.
///
/// A separate actor because it is written to from an event loop thread and read
/// from a task, and the two must not share state without a boundary. Buffered
/// rather than dropped: the sending machine may be a step ahead, and a tensor
/// discarded because nobody was waiting yet is a token that never completes.
actor FrameInbox {
    private var queue: [TensorFrame] = []
    private var waiter: CheckedContinuation<TensorFrame, Error>?
    private var failure: Error?

    func deliver(_ frame: TensorFrame) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: frame)
        } else {
            queue.append(frame)
        }
    }

    /// Record why the link stopped working, keeping the *first* reason.
    ///
    /// Closing a channel makes it go inactive, so a handshake failure is
    /// immediately followed by a "peer closed" that would otherwise overwrite
    /// it. Every real cause then arrives at the operator as "the other machine
    /// closed the link", which says nothing about a wrong trust root, an
    /// expired certificate or a rejected frame.
    func fail(_ error: Error) {
        if failure == nil { failure = error }
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: failure ?? error)
        }
    }

    func finish() {
        fail(PipelineChannel.Failure.peerClosed)
    }

    func next() async throws -> TensorFrame {
        if !queue.isEmpty { return queue.removeFirst() }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { continuation in
            self.waiter = continuation
        }
    }
}

/// Decodes the stream and hands whole frames to the inbox.
final class FrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var decoder = TensorFrameDecoder()
    private let inbox: FrameInbox

    /// The last delivery, so the next one can wait for it.
    ///
    /// Frames arrive in order - `channelRead` runs on one event loop thread and
    /// TCP does not reorder - and that order was being thrown away on the last
    /// step. Delivering each frame from its own unstructured `Task` hands them
    /// to the scheduler as independent pieces of work, and two of them can run
    /// in either order. Under load they do.
    ///
    /// This corrupts a pipeline silently. A hidden state that arrives one step
    /// early is the right shape and the wrong contents, so the model answers
    /// fluently from a conversation that never happened. Chaining each delivery
    /// behind the previous one restores the order the network already had.
    private var lastDelivery: Task<Void, Never>?

    init(inbox: FrameInbox) { self.inbox = inbox }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        do {
            let frames = try decoder.push(Data(bytes))
            guard !frames.isEmpty else { return }
            let previous = lastDelivery
            lastDelivery = Task { [inbox] in
                await previous?.value
                for frame in frames { await inbox.deliver(frame) }
            }
        } catch {
            // A malformed frame ends the link rather than being skipped. There
            // is no way to resynchronise a stream whose framing is wrong, and
            // guessing where the next frame starts would feed a model whatever
            // the guess landed on.
            Task { await inbox.fail(error) }
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        Task { await inbox.fail(PipelineChannel.Failure.peerClosed) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Task { await inbox.fail(PipelineChannel.Failure.transport(String(describing: error))) }
        context.close(promise: nil)
    }
}

/// Says whether the two machines actually agreed to talk.
///
/// Sits directly behind the TLS handler so it sees the handshake result before
/// anything reads a byte. Both outcomes are worth a line and neither was
/// reported before: a completed handshake is the moment the link becomes real,
/// and a refused one is the whole answer to why a split hangs - it arrives as an
/// error here, is passed on to fail whoever is waiting, and previously vanished
/// because nothing in the pipeline had anything to say about it.
///
/// Passes everything on rather than consuming it. This watches; the handler
/// behind it is what does something about it.
final class HandshakeWatcher: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let log: @Sendable (String) -> Void
    private let deadline: TimeAmount
    private var timeout: Scheduled<Void>?
    private var completed = false

    /// Ten seconds, which is generous for two machines on a cable and short
    /// enough to be worth reading. The link this runs over is measured in
    /// fractions of a millisecond; a handshake still unfinished after ten
    /// seconds is not slow, it is not happening.
    init(log: @escaping @Sendable (String) -> Void,
         deadline: TimeAmount = .seconds(10)) {
        self.log = log
        self.deadline = deadline
    }

    /// A link that goes quiet mid-handshake has to end, not wait.
    ///
    /// This is what a Thunderbolt bridge dropping looks like from inside: no
    /// error, no close, no bytes. TCP has nothing to report because nothing was
    /// refused, so the listener sat through its whole two minute read waiting
    /// for a hidden state, and the dialer's first write stayed queued behind a
    /// handshake that would never finish. Both machines held half a model
    /// meanwhile, and what they eventually said was that the other one had not
    /// answered - true, and no help at all in finding out why.
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        timeout = context.eventLoop.scheduleTask(in: deadline) { [weak self, log] in
            guard let self, !self.completed else { return }
            let peer = channel.remoteAddress.map(String.init(describing:)) ?? "the peer"
            log("pipeline: no handshake with \(peer) after \(self.deadline.nanoseconds / 1_000_000_000)s;"
                + " giving up on the link")
            channel.pipeline.fireErrorCaught(PipelineChannel.Failure.handshakeTimedOut)
            channel.close(promise: nil)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        timeout?.cancel()
        timeout = nil
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            completed = true
            timeout?.cancel()
            timeout = nil
            log("pipeline: handshake completed with "
                + "\(context.channel.remoteAddress.map(String.init(describing:)) ?? "the peer")")
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Named as the peer's refusal rather than as a socket error, because
        // that is what it almost always is: the certificate one machine presents
        // is not one the other will accept, and every other explanation for a
        // link that never carries a byte is rarer than that.
        log("pipeline: link failed: \(error)")
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        log("pipeline: the peer closed the link")
        context.fireChannelInactive()
    }
}
