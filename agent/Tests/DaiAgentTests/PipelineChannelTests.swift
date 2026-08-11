import Foundation
import NIOPosix
import NIOSSL
import Testing
@testable import DaiAgent

/// Two halves of a model talking to each other, over a real socket.
///
/// Loopback rather than Thunderbolt, deliberately. The cable changes the latency
/// and nothing else: fragmentation, the handshake, framing and partial reads all
/// happen identically over 127.0.0.1, and every bug this code can have is
/// reachable without leaving the machine. What a second machine is needed for is
/// the layer above, where one half of a pair disappears.
///
/// A throwaway certificate authority is generated per run rather than using the
/// Secure Enclave, because an Enclave key cannot be created in a test process.
/// The signing path differs; everything above it - handshake, framing, partial
/// reads, peer loss - is the code that ships.
@Suite(.serialized)
struct PipelineChannelTests {
    private func frame(_ shape: [Int] = [1, 8],
                       fill: UInt8 = 7,
                       dtype: TensorFrame.DType = .float16) -> TensorFrame {
        TensorFrame(shape: shape, dtype: dtype,
                    bytes: Data(repeating: fill, count: shape.reduce(1, *) * dtype.byteWidth))
    }

    @Test("a hidden state arrives byte for byte")
    func deliversUnchanged() async throws {
        // The whole contract. What the second machine puts into its layers has
        // to be exactly what the first machine produced, because a tensor that
        // is subtly wrong yields a confident answer rather than an error.
        let inbox = FrameInbox()
        let sent = frame([1, 1, 8192], fill: 0xA5, dtype: .bfloat16)

        var decoder = TensorFrameDecoder()
        for chunk in TensorCodec.encode(sent).chunked(into: 1500) {
            for f in try decoder.push(chunk) { await inbox.deliver(f) }
        }
        let got = try await inbox.next()
        #expect(got == sent)
        #expect(got.bytes.count == 16_384)
    }

    @Test("a tensor that arrives before anyone asks for it is kept")
    func buffersAhead() async throws {
        // The sending machine can be a step ahead. A frame dropped because
        // nobody was waiting yet is a token that never completes, and the job
        // hangs rather than fails.
        let inbox = FrameInbox()
        let first = frame(fill: 1), second = frame(fill: 2)
        await inbox.deliver(first)
        await inbox.deliver(second)

        #expect(try await inbox.next() == first)
        #expect(try await inbox.next() == second)
    }

    @Test("a waiting reader is woken by the next arrival")
    func wakesTheWaiter() async throws {
        let inbox = FrameInbox()
        let expected = frame(fill: 9)

        async let received = inbox.next()
        try await Task.sleep(for: .milliseconds(50))
        await inbox.deliver(expected)
        #expect(try await received == expected)
    }

    @Test("a reader waiting when the link drops is told, rather than left hanging")
    func failsTheWaiterOnClose() async throws {
        // The failure that matters most: the other machine goes away mid-token.
        // A reader that waits forever turns a dead peer into a job that never
        // finishes and a machine that is never freed.
        let inbox = FrameInbox()
        let waiting = Task { try await inbox.next() }
        try await Task.sleep(for: .milliseconds(50))
        await inbox.finish()

        await #expect(throws: PipelineChannel.Failure.self) { try await waiting.value }
    }

    @Test("a reader arriving after the link dropped is told immediately")
    func failsLateReaders() async throws {
        let inbox = FrameInbox()
        await inbox.finish()
        await #expect(throws: PipelineChannel.Failure.self) { try await inbox.next() }
    }

    @Test("sending without a peer fails rather than pretending")
    func refusesToSendUnconnected() async throws {
        let channel = PipelineChannel()
        await #expect(throws: PipelineChannel.Failure.self) {
            try await channel.send(frame())
        }
        await channel.close()
    }

    @Test("a malformed stream ends the link instead of guessing")
    func malformedEndsTheLink() async throws {
        // There is no way to resynchronise a stream whose framing is wrong.
        // Skipping ahead to the next plausible header would feed a model
        // whatever the guess landed on.
        var decoder = TensorFrameDecoder()
        #expect(throws: TensorCodec.Failure.self) {
            try decoder.push(Data(repeating: 0xEE, count: 64))
        }
    }
}

private extension Data {
    /// Split into fragments, the way a socket would.
    func chunked(into size: Int) -> [Data] {
        stride(from: 0, to: count, by: size).map {
            subdata(in: (startIndex + $0) ..< Swift.min(startIndex + $0 + size, endIndex))
        }
    }
}

/// The socket, end to end.
///
/// Two mutually authenticated endpoints in one process over loopback. The cable
/// changes latency and nothing else: fragmentation, the handshake and framing
/// are identical over 127.0.0.1, so every bug this code can have is reachable
/// without a second machine.
@Suite(.serialized)
struct PipelineChannelSocketTests {
    /// A CA and two certificates it signed, valid for a few minutes.
    struct Fixture {
        let dir: URL
        let caPEM: String
        var serverContext: NIOSSLContext
        var clientContext: NIOSSLContext
    }

    private func openssl(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "openssl", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: args.joined(separator: " ")])
        }
    }

    private func fixture() throws -> Fixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dai-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key",
                     "-out", "ca.crt", "-days", "1", "-subj", "/CN=dai-test-ca"], in: dir)
        for who in ["server", "client"] {
            try openssl(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "\(who).key",
                         "-out", "\(who).csr", "-subj", "/CN=localhost"], in: dir)
            try openssl(["x509", "-req", "-in", "\(who).csr", "-CA", "ca.crt", "-CAkey",
                         "ca.key", "-CAcreateserial", "-out", "\(who).crt", "-days", "1"],
                        in: dir)
        }

        let caPEM = try String(contentsOf: dir.appendingPathComponent("ca.crt"), encoding: .utf8)
        let roots = try NIOSSLCertificate.fromPEMBytes(Array(caPEM.utf8))

        func context(_ who: String, server: Bool) throws -> NIOSSLContext {
            let chain = try NIOSSLCertificate
                .fromPEMFile(dir.appendingPathComponent("\(who).crt").path)
                .map { NIOSSLCertificateSource.certificate($0) }
            let key = NIOSSLPrivateKeySource.privateKey(
                try NIOSSLPrivateKey(file: dir.appendingPathComponent("\(who).key").path,
                                     format: .pem))
            var config = server
                ? TLSConfiguration.makeServerConfiguration(certificateChain: chain, privateKey: key)
                : TLSConfiguration.makeClientConfiguration()
            if !server {
                config.certificateChain = chain
                config.privateKey = key
            }
            // Both ends verify the other against the fleet CA and nothing else.
            config.certificateVerification = .noHostnameVerification
            config.trustRoots = .certificates(roots)
            return try NIOSSLContext(configuration: config)
        }

        return Fixture(dir: dir, caPEM: caPEM,
                       serverContext: try context("server", server: true),
                       clientContext: try context("client", server: false))
    }

    private func hiddenState(_ fill: UInt8) -> TensorFrame {
        TensorFrame(shape: [1, 1, 8192], dtype: .bfloat16,
                    bytes: Data(repeating: fill, count: 8192 * 2))
    }

    @Test("a hidden state crosses a real mutually authenticated connection")
    func realRoundTrip() async throws {
        let fx = try fixture()
        defer { try? FileManager.default.removeItem(at: fx.dir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let later = PipelineChannel(group: group)   // holds the later layers, listens
        let earlier = PipelineChannel(group: group) // holds the earlier layers, connects

        // Port 0 lets the kernel choose, so a test run never collides with
        // whatever else is listening on a developer's machine.
        let port = try await later.listen(port: 0, tls: fx.serverContext)

        try await earlier.connect(host: "127.0.0.1", port: port,
                                  tls: fx.clientContext, serverName: "localhost")

        let sent = hiddenState(0xA5)
        try await earlier.send(sent)
        #expect(try await later.receive() == sent)

        // And the token going back the other way.
        let token = TensorFrame(shape: [1], dtype: .uint32, bytes: Data([7, 0, 0, 0]))
        try await later.send(token)
        #expect(try await earlier.receive() == token)

        await earlier.close()
        await later.close()
        try? await group.shutdownGracefully()
    }

    @Test("several tensors in flight keep their order")
    func ordered() async throws {
        // A pipeline sends one per token and the receiver consumes them in
        // sequence. Out of order delivery would corrupt a conversation silently.
        let fx = try fixture()
        defer { try? FileManager.default.removeItem(at: fx.dir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let later = PipelineChannel(group: group)
        let earlier = PipelineChannel(group: group)

        let port = try await later.listen(port: 0, tls: fx.serverContext)
        try await earlier.connect(host: "127.0.0.1", port: port,
                                  tls: fx.clientContext, serverName: "localhost")

        for i in 0..<8 { try await earlier.send(hiddenState(UInt8(i))) }
        for i in 0..<8 {
            #expect(try await later.receive() == hiddenState(UInt8(i)), "token \(i) out of order")
        }

        await earlier.close()
        await later.close()
        try? await group.shutdownGracefully()
    }

    @Test("the other machine going away is reported, not waited on forever")
    func peerLoss() async throws {
        // The failure that will actually happen: a machine sleeps, or its owner
        // sits down, halfway through a sequence. A reader that waits forever
        // turns that into a job that never finishes and capacity never freed.
        let fx = try fixture()
        defer { try? FileManager.default.removeItem(at: fx.dir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let later = PipelineChannel(group: group)
        let earlier = PipelineChannel(group: group)

        let port = try await later.listen(port: 0, tls: fx.serverContext)
        try await earlier.connect(host: "127.0.0.1", port: port,
                                  tls: fx.clientContext, serverName: "localhost")

        let waiting = Task { try await later.receive() }
        try await Task.sleep(for: .milliseconds(100))
        await earlier.close()

        await #expect(throws: (any Error).self) { try await waiting.value }
        await later.close()
        try? await group.shutdownGracefully()
    }

    @Test("a peer with no certificate from our CA is refused")
    func refusesStranger() async throws {
        // The link carries a tensor that the receiving machine feeds straight
        // into a model. Anyone who can reach the port must not be able to do
        // that: this is an authorisation boundary, not a transport detail.
        let ours = try fixture()
        let theirs = try fixture()   // a different CA entirely
        defer {
            try? FileManager.default.removeItem(at: ours.dir)
            try? FileManager.default.removeItem(at: theirs.dir)
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let later = PipelineChannel(group: group)
        let stranger = PipelineChannel(group: group)

        let port = try await later.listen(port: 0, tls: ours.serverContext)

        var refused = false
        do {
            try await stranger.connect(host: "127.0.0.1", port: port,
                                       tls: theirs.clientContext, serverName: "localhost")
            // The handshake may complete locally and fail on first use, so the
            // send is part of the assertion rather than the connect alone.
            try await stranger.send(hiddenState(1))
            _ = try await later.receive()
        } catch {
            refused = true
        }
        #expect(refused, "a stranger's certificate was accepted")

        await stranger.close()
        await later.close()
        try? await group.shutdownGracefully()
    }
    @Test("an address is never offered as a server name")
    func sniRejectsAddresses() {
        // TLS forbids an address in SNI, and NIOSSL enforces it by throwing
        // rather than by dropping the field. A peer reached by address is
        // ordinary here: a machine on a Thunderbolt bridge has 192.168.99.2 and
        // no name anybody resolves.
        #expect(PipelineChannel.sniName(for: "127.0.0.1") == nil)
        #expect(PipelineChannel.sniName(for: "192.168.99.2") == nil)
        #expect(PipelineChannel.sniName(for: "::1") == nil)
        #expect(PipelineChannel.sniName(for: "fe80::1") == nil)
        #expect(PipelineChannel.sniName(for: "") == nil)
    }

    @Test("a real name is still offered")
    func sniKeepsNames() {
        #expect(PipelineChannel.sniName(for: "orca.local") == "orca.local")
        #expect(PipelineChannel.sniName(for: "rotorua") == "rotorua")
    }

    @Test("the first reason a link failed is the one reported")
    func keepsFirstFailure() async throws {
        // Closing a channel makes it go inactive, so every real cause was being
        // overwritten a moment later by "the other machine closed the link".
        // An operator then cannot tell a wrong trust root from a pulled cable.
        let inbox = FrameInbox()
        struct Real: Error, Equatable {}
        await inbox.fail(Real())
        await inbox.fail(PipelineChannel.Failure.peerClosed)
        await #expect(throws: Real.self) { try await inbox.next() }
    }

}
