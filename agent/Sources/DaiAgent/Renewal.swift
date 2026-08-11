import Foundation
import NIOSSL

/// Keeping a node's certificate current, without anybody visiting the machine.
///
/// Certificates here last thirty days, deliberately. These live on laptops that
/// leave the building, and a machine that stops checking in should stop being a
/// fleet member on its own rather than because somebody remembered to revoke
/// it. That is only an affordable property if the machines that *are* still
/// here renew unattended: without this, expiry is indistinguishable from an
/// outage, and the remedy is walking to every machine once a month.
///
/// Renewal needs no human. The node calls with the certificate it already
/// holds, which proves it controls the key that certificate names, so there is
/// nothing left to decide that was not decided at approval.
public enum Renewal {
    /// When to ask, expressed as how far through its life a certificate is.
    ///
    /// Two thirds, which for a thirty-day certificate means asking with ten
    /// days to spare. The margin is not politeness: it is how many consecutive
    /// failed attempts the node can survive. A machine that renewed at the last
    /// moment would need the control plane reachable on exactly that day, and
    /// these are machines that spend weekends asleep.
    public static let elapsedFraction = 2.0 / 3.0

    /// Whether a certificate with this lifetime should be renewed now.
    ///
    /// Expressed as a fraction of the whole life rather than a fixed number of
    /// days, so shortening the issued lifetime tightens the renewal interval
    /// with it instead of quietly leaving nodes renewing too late.
    public static func due(notBefore: Date, notAfter: Date, now: Date,
                           elapsedFraction: Double = Renewal.elapsedFraction) -> Bool {
        let life = notAfter.timeIntervalSince(notBefore)
        // A certificate with no measurable life is not one to reason about.
        // Renewing immediately is the safe reading: something is wrong with it
        // and a fresh one is the remedy.
        guard life > 0 else { return true }
        return now.timeIntervalSince(notBefore) >= life * elapsedFraction
    }

    /// The validity window of a PEM certificate.
    ///
    /// Read from the certificate rather than remembered from issuance, because
    /// what matters is the document the control plane will check, not what this
    /// process believes about it.
    public static func validity(certificatePEM: String) throws -> (notBefore: Date,
                                                                   notAfter: Date) {
        let certs = try NIOSSLCertificate.fromPEMBytes(Array(certificatePEM.utf8))
        guard let cert = certs.first else { throw Failure.unreadableCertificate }
        return (Date(timeIntervalSince1970: TimeInterval(cert.notValidBefore)),
                Date(timeIntervalSince1970: TimeInterval(cert.notValidAfter)))
    }

    public enum Failure: Error, CustomStringConvertible {
        case unreadableCertificate

        public var description: String {
            switch self {
            case .unreadableCertificate: return "the certificate on disk could not be read"
            }
        }
    }
}

/// Something that will renew this node's certificate when it is time.
///
/// A protocol so the worker loop can be tested without a control plane or a
/// Secure Enclave, neither of which exists in a test process.
public protocol CertificateRenewing: Sendable {
    /// Renew if due. Returns a replacement client when the identity changed,
    /// and nil when nothing needed doing.
    ///
    /// A replacement is necessary rather than tidy. Renewal retires the old
    /// certificate the moment the new one is issued, so a client still holding
    /// the old one starts being told it is unknown. Handing back a new client
    /// is what closes that window.
    func renewIfDue(now: Date) async -> (any ControlPlaneClient)?
}

/// Renews against a real control plane, writing the result where the daemon
/// and the next process start will both find it.
public actor CertificateRenewer: CertificateRenewing {
    /// Builds a client that presents the renewed identity.
    ///
    /// Supplied by the caller because the control plane's address and its CA
    /// are the caller's business, and this type should not have to be told
    /// about either in order to know when a certificate is old.
    public typealias Rebuild = @Sendable (NodeIdentity, String?) throws -> any ControlPlaneClient

    private let directory: URL
    private let keyPath: URL
    private let rebuild: Rebuild
    private var client: any ControlPlaneClient
    private let log: @Sendable (String) -> Void

    /// Not retried tightly. A control plane that is down will still be down in
    /// a minute, and there are days of margin left.
    private var nextAttempt = Date.distantPast
    private static let retryInterval: TimeInterval = 3600

    public init(directory: URL, keyPath: URL, client: any ControlPlaneClient,
                rebuild: @escaping Rebuild,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.directory = directory
        self.keyPath = keyPath
        self.client = client
        self.rebuild = rebuild
        self.log = log
    }

    private var certificatePath: URL { directory.appendingPathComponent("node.crt") }

    public func renewIfDue(now: Date = Date()) async -> (any ControlPlaneClient)? {
        guard now >= nextAttempt else { return nil }
        guard let pem = try? String(contentsOf: certificatePath, encoding: .utf8),
              let window = try? Renewal.validity(certificatePEM: pem),
              Renewal.due(notBefore: window.notBefore, notAfter: window.notAfter, now: now)
        else { return nil }

        nextAttempt = now.addingTimeInterval(Self.retryInterval)

        do {
            // The same key, which is the ordinary case: it lives in the Secure
            // Enclave, cannot leave the machine and has no reason to change.
            let key = try EnclaveKey.loadOrCreate(at: keyPath)
            let csr = try CSR.create(commonName: MachineName.current(), key: key)
            let renewed = try await client.renew(csrPEM: csr)

            // Written before the client is replaced, so a crash in between
            // leaves the machine holding the certificate the control plane has
            // already switched to rather than one it has stopped accepting.
            try write(renewed.certPEM, to: certificatePath)
            if let serverCA = renewed.serverCAPEM {
                try write(serverCA, to: directory.appendingPathComponent("ca.crt"))
            }
            // Nodes enrolled before machines talked to each other have no node
            // CA at all, and cannot be the listening half of a split model
            // without one. This is how they acquire it.
            if let nodeCA = renewed.nodeCAPEM {
                try write(nodeCA, to: directory.appendingPathComponent("node-ca.crt"))
            }

            let until = (try? Renewal.validity(certificatePEM: renewed.certPEM))?.notAfter
            log("certificate renewed" + (until.map { ", good until \($0)" } ?? ""))

            let identity = NodeIdentity(certificatePEM: renewed.certPEM, key: key)
            let replacement = try rebuild(identity, renewed.serverCAPEM)
            client = replacement
            return replacement
        } catch {
            // Best effort, and loudly. There are days of margin left, so one
            // failure is not an emergency - but a run of them ends with a node
            // dropping out of the fleet, and the log is where that becomes
            // visible before it happens.
            log("certificate renewal failed: \(error)")
            return nil
        }
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
