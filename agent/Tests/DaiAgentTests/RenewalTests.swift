import Foundation
import Testing
@testable import DaiAgent
@testable import DaiWorker

/// Deciding when a certificate is old enough to replace.
///
/// Worth testing precisely because nothing here fails visibly when it is wrong.
/// A node that renews too late works perfectly until the day it does not, and
/// the symptom then is a machine that has silently left the fleet, which reads
/// like an outage rather than a certificate.
struct RenewalDecisionTests {
    private let day: TimeInterval = 86_400

    private func window(days: Double, from: Date = Date(timeIntervalSince1970: 1_000_000))
        -> (notBefore: Date, notAfter: Date) {
        (from, from.addingTimeInterval(days * 86_400))
    }

    @Test("a fresh certificate is left alone")
    func freshIsLeftAlone() {
        let w = window(days: 30)
        #expect(!Renewal.due(notBefore: w.notBefore, notAfter: w.notAfter,
                             now: w.notBefore))
        #expect(!Renewal.due(notBefore: w.notBefore, notAfter: w.notAfter,
                             now: w.notBefore.addingTimeInterval(19 * day)))
    }

    @Test("renewal starts with days of margin, not hours")
    func renewsWithMargin() {
        // Two thirds of thirty days leaves ten days to keep trying. The margin
        // is the number of consecutive failures a node can survive, and these
        // are machines that spend weekends asleep: renewing at the last moment
        // would need the control plane reachable on exactly one day.
        let w = window(days: 30)
        #expect(Renewal.due(notBefore: w.notBefore, notAfter: w.notAfter,
                            now: w.notBefore.addingTimeInterval(20 * day)))
        let remaining = w.notAfter.timeIntervalSince(w.notBefore.addingTimeInterval(20 * day))
        #expect(remaining / day == 10)
    }

    @Test("a shorter certificate renews sooner, without anyone adjusting a constant")
    func scalesWithLifetime() {
        // The threshold is a fraction of the life rather than a fixed number of
        // days, so shortening what the CA issues tightens renewal with it. A
        // hardcoded "renew at 20 days" would leave a 7-day certificate renewing
        // 13 days after it expired.
        let short = window(days: 7)
        #expect(Renewal.due(notBefore: short.notBefore, notAfter: short.notAfter,
                            now: short.notBefore.addingTimeInterval(5 * day)))
        #expect(!Renewal.due(notBefore: short.notBefore, notAfter: short.notAfter,
                             now: short.notBefore.addingTimeInterval(4 * day)))
    }

    @Test("an expired certificate is due, not ignored")
    func expiredIsDue() {
        // Renewal will be refused for a lapsed certificate, and that refusal is
        // the control plane's to make. What must not happen is the node
        // deciding for itself that there is nothing to try.
        let w = window(days: 30)
        #expect(Renewal.due(notBefore: w.notBefore, notAfter: w.notAfter,
                            now: w.notAfter.addingTimeInterval(day)))
    }

    @Test("a certificate with no life left is due immediately")
    func degenerateWindow() {
        // Something is wrong with a certificate whose validity is empty or
        // inverted. Asking for a new one is the right reading of that.
        let at = Date(timeIntervalSince1970: 1_000_000)
        #expect(Renewal.due(notBefore: at, notAfter: at, now: at))
        #expect(Renewal.due(notBefore: at, notAfter: at.addingTimeInterval(-day), now: at))
    }
}

/// Renewing inside the loop that runs for as long as a machine is a member.
///
/// The Secure Enclave cannot generate a key inside a test process, so what is
/// exercised here is everything above the key: whether the loop asks, and
/// whether it actually starts using what it is handed back.
struct RenewalLoopTests {
    /// A renewer whose answer is fixed, standing in for one that talks to a
    /// control plane and writes files.
    actor Fixed: CertificateRenewing {
        private let replacement: (any ControlPlaneClient)?
        /// Whether the clock would say yes. False stands for the ordinary case -
        /// a certificate with most of its life left - which is the only state in
        /// which asking for a renewal means anything.
        private let due: Bool
        private var handedOut = false
        private(set) var calls = 0
        private(set) var askedCalls = 0

        init(replacement: (any ControlPlaneClient)? = nil, due: Bool = true) {
            self.replacement = replacement
            self.due = due
        }

        func renewIfDue(now: Date) async -> (any ControlPlaneClient)? {
            calls += 1
            guard due else { return nil }
            // Once, like the real one: a renewer that handed back a new client
            // every pass would have the loop rebuilding its connection forever.
            guard !handedOut, let replacement else { return nil }
            handedOut = true
            return replacement
        }

        /// Asked rather than due. Counted separately so a test can tell which
        /// path the loop took, which is the whole question.
        func renewNow(now: Date) async -> (any ControlPlaneClient)? {
            askedCalls += 1
            guard !handedOut, let replacement else { return nil }
            handedOut = true
            return replacement
        }

        func callCount() -> Int { calls }
        func askedCount() -> Int { askedCalls }
    }

    private func statusPath() -> String {
        NSTemporaryDirectory() + "dai-renewal-\(UUID().uuidString).json"
    }

    @Test("the loop asks whether renewal is due")
    func asksEveryPass() async {
        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let renewer = Fixed()

        let worker = Worker(controlPlane: FakeControlPlane(), source: FixedSignals.present(),
                            gpu: nil, ane: nil, status: StatusPublisher(path: path),
                            renewer: renewer, promoteAfter: 0)
        await worker.run(maxSeconds: 0.6)

        // In the loop rather than on a timer of its own, because this is the
        // loop that runs for as long as the machine is a fleet member. Asking
        // costs a comparison; the renewer decides whether anything is due.
        #expect(await renewer.callCount() > 0)
    }

    @Test("a renewed identity is the one the loop then uses")
    func swapsToTheRenewedClient() async {
        // The point of handing a client back. Renewal retires the old
        // certificate the moment the new one is issued, so a loop that kept
        // heartbeating on the old one would be told it was unknown and would
        // drop out of the fleet at the very moment it had just renewed.
        let old = FakeControlPlane()
        let new = FakeControlPlane()
        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let worker = Worker(controlPlane: old, source: FixedSignals.present(),
                            gpu: nil, ane: nil, status: StatusPublisher(path: path),
                            renewer: Fixed(replacement: new), promoteAfter: 0)
        await worker.run(maxSeconds: 1.2)

        #expect(await new.heartbeats.count > 0)
    }

    @Test("a loop with no renewer still runs")
    func optionalRenewer() async {
        // A one-shot run and a test have no identity on disk to renew, and
        // neither should be unable to start because of it.
        let cp = FakeControlPlane()
        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let worker = Worker(controlPlane: cp, source: FixedSignals.present(),
                            gpu: nil, ane: nil, status: StatusPublisher(path: path),
                            promoteAfter: 0)
        await worker.run(maxSeconds: 0.6)
        #expect(await cp.heartbeats.count > 0)
    }

    @Test("an unreadable certificate is reported, not guessed at")
    func unreadableCertificate() {
        #expect(throws: (any Error).self) {
            try Renewal.validity(certificatePEM: "not a certificate")
        }
    }

    @Test("the validity window comes off the certificate itself")
    func readsTheCertificateNotAMemory() throws {
        // Read from the document the control plane will check, rather than
        // remembered from issuance. A process trusting its own memory would
        // keep believing a certificate that an operator replaced underneath it
        // with `dai-agent renew`.
        let pem = try #require(Self.sampleCertificate)
        let window = try Renewal.validity(certificatePEM: pem)
        let days = window.notAfter.timeIntervalSince(window.notBefore) / 86_400
        #expect(days > 29 && days < 31)
        #expect(!Renewal.due(notBefore: window.notBefore, notAfter: window.notAfter,
                             now: window.notBefore))
    }

    /// A real certificate to parse, made with openssl rather than pasted, so
    /// this keeps testing the parser rather than one frozen sample.
    static let sampleCertificate: String? = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dai-renewal-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-x509", "-newkey", "ec",
                             "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                             "-keyout", dir.appendingPathComponent("k.pem").path,
                             "-out", dir.appendingPathComponent("c.pem").path,
                             "-days", "30", "-subj", "/CN=test-node"]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return try? String(contentsOf: dir.appendingPathComponent("c.pem"), encoding: .utf8)
    }()
}

/// Renewing because somebody asked, rather than because it is time.
///
/// The Enclave key signs only inside the daemon, so a renewal cannot be run
/// from any other session - `dai-agent renew` over ssh fails with "unable to
/// sign digest" even as root. And the daemon renews on its own only at two
/// thirds of certificate life. Between those two facts, a node that needs a new
/// certificate today has no way to get one, which is what this closes.
struct RenewOnRequestTests {
    @Test("a request renews a certificate the clock would refuse")
    func askedBeatsDue() async throws {
        // Three days into thirty: nowhere near due, and the case that prompted
        // this - both machines in the fleet enrolled before nodes had to trust
        // each other and cannot join a split without a node CA.
        // due: false is the point. A renewer that would renew on the clock
        // anyway proves nothing, and an earlier version of this test failed for
        // exactly that reason - the loop renewed on the first pass, before the
        // first heartbeat had even been sent.
        let renewer = RenewalLoopTests.Fixed(replacement: FakeControlPlane(), due: false)
        let cp = FakeControlPlane()
        await cp.setDirectives(.init(renewRequested: true))

        let worker = Worker(controlPlane: cp, source: FixedSignals.present(),
                            renewer: renewer, promoteAfter: 0)
        // Two turns' worth: the flag is set by the heartbeat partway through a
        // turn and read at the top of the next one.
        await worker.run(maxSeconds: 1.5)

        #expect(await renewer.askedCount() > 0, "the loop should have renewed on request")
    }

    @Test("no request leaves the clock in charge")
    func unaskedUsesTheClock() async throws {
        let renewer = RenewalLoopTests.Fixed(replacement: FakeControlPlane(), due: false)
        let cp = FakeControlPlane()   // directives default to nothing asked

        let worker = Worker(controlPlane: cp, source: FixedSignals.present(),
                            renewer: renewer, promoteAfter: 0)
        await worker.run(maxSeconds: 1.5)

        #expect(await renewer.askedCount() == 0)
        #expect(await renewer.callCount() > 0, "the ordinary due check should still run")
    }
}
