import DaiAgent
import Foundation

/// Enrollment, kept separate because it happens once and needs a human in the
/// middle: a join token gets a node into a queue, an admin decides whether it
/// becomes a member.
///
/// The private key is generated in the Secure Enclave and never leaves it. What
/// lands on disk is a blob the Enclave sealed to this machine, so a copy taken
/// from a stolen laptop is inert: the certificate names a key the thief cannot
/// use. That is the difference between an identity and a file.
enum Enroll {
    /// Where the node's identity lives.
    ///
    /// `DAI_IDENTITY_DIR` overrides it because `NSHomeDirectory()` reads the
    /// password database rather than `HOME`, so a daemon running as a service
    /// account cannot be pointed elsewhere by environment alone - and neither
    /// can a test, which is how this was noticed.
    static func identityDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["DAI_IDENTITY_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dai/identity")
    }

    static func hardware() -> (chip: String, memoryGb: Double) {
        var size = 0
        sysctlbyname("hw.memsize", nil, &size, nil, 0)
        var bytes: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &bytes, &len, nil, 0)

        var chipSize = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &chipSize, nil, 0)
        var chipBuf = [CChar](repeating: 0, count: chipSize)
        sysctlbyname("machdep.cpu.brand_string", &chipBuf, &chipSize, nil, 0)

        return (String(cString: chipBuf), Double(bytes) / 1_073_741_824)
    }

    /// Where the sealed Enclave blob lives. Deliberately not `node.key`: that
    /// name held an RSA PEM in the previous scheme, and a node carrying one
    /// should fail loudly and be re-enrolled rather than have the two confused.
    static func keyPath(_ dir: URL) -> URL { dir.appendingPathComponent("node.enclave-key") }

    static func generateCSR(dir: URL, commonName: String) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let csrPath = dir.appendingPathComponent("node.csr")

        // Reuse an outstanding request rather than making a new one. A fresh key
        // would orphan the pending node record, which already holds the public
        // half of the old one.
        if let existing = try? String(contentsOf: csrPath, encoding: .utf8), !existing.isEmpty {
            return existing
        }

        // The CN is ignored by the issuer: the control plane names the
        // certificate after the node record, so a machine cannot request an
        // identity belonging to another node. It goes in so a human reading the
        // pending queue has something recognisable.
        let key = try EnclaveKey.loadOrCreate(at: keyPath(dir))
        let csr = try CSR.create(commonName: commonName, key: key)
        try csr.write(to: csrPath, atomically: true, encoding: .utf8)
        return csr
    }

    static func run(controlPlane: URL, joinToken: String, caPath: String?,
                    waitSeconds: Double) async throws {
        let dir = identityDir()
        let certPath = dir.appendingPathComponent("node.crt")
        if FileManager.default.fileExists(atPath: certPath.path) {
            print("Already enrolled. Identity in \(dir.path)"); return
        }

        let host = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "node"
        let hw = hardware()
        let csr = try generateCSR(dir: dir, commonName: host)

        // The bootstrap bundle is three things: URL, join token, and the server
        // CA. A node must verify the control plane before it has an identity, so
        // the CA has to arrive out of band.
        let ca = try caPath.map { try String(contentsOfFile: $0, encoding: .utf8) }
        let cp = try ControlPlane(base: controlPlane, identity: nil, serverCAPEM: ca)
        defer { Task { await cp.shutdown() } }

        let nodeFile = dir.appendingPathComponent("node-id")
        let tokenFile = dir.appendingPathComponent("enrollment-token")

        let nodeId: String
        let enrollmentToken: String
        // Resume rather than re-enroll. Doing this twice used to create a second
        // pending node and poll for it, stranding the first in the queue.
        if let id = try? String(contentsOf: nodeFile, encoding: .utf8),
           let tok = try? String(contentsOf: tokenFile, encoding: .utf8) {
            nodeId = id.trimmingCharacters(in: .whitespacesAndNewlines)
            enrollmentToken = tok.trimmingCharacters(in: .whitespacesAndNewlines)
            FileHandle.standardError.write("Resuming enrollment for \(nodeId)\n".data(using: .utf8)!)
        } else {
            let e = try await cp.enroll(joinToken: joinToken, hostname: host, chip: hw.chip,
                                        machineId: MachineIdentity.platformUUID(),
                                        memoryGb: hw.memoryGb,
                                        metalWorkingSetGb: MetalInfo.workingSetGb(),
                                        osVersion: ProcessInfo.processInfo
                                            .operatingSystemVersionString,
                                        csrPEM: csr)
            nodeId = e.nodeId; enrollmentToken = e.enrollmentToken
            try nodeId.write(to: nodeFile, atomically: true, encoding: .utf8)
            try enrollmentToken.write(to: tokenFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: tokenFile.path)
            print("nodeId \(nodeId)\nstate   pending")
        }

        guard waitSeconds > 0 else {
            FileHandle.standardError.write("Pending approval.\n".data(using: .utf8)!); return
        }

        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline {
            if let issued = try await cp.collectCertificate(nodeId: nodeId,
                                                           enrollmentToken: enrollmentToken) {
                try issued.certPEM.write(to: certPath, atomically: true, encoding: .utf8)
                // The *server* CA. The node CA signs agent identities and is not
                // useful here; pinning it by mistake fails every later
                // connection with an error that reads like a network problem.
                if let serverCA = issued.serverCAPEM {
                    try serverCA.write(to: dir.appendingPathComponent("ca.crt"),
                                       atomically: true, encoding: .utf8)
                } else if let caPath {
                    try FileManager.default.copyItem(atPath: caPath,
                        toPath: dir.appendingPathComponent("ca.crt").path)
                }
                try? FileManager.default.removeItem(at: tokenFile)
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("node.csr"))
                FileHandle.standardError.write(
                    "Approved. Identity written to \(dir.path)\n".data(using: .utf8)!)
                return
            }
            try await Task.sleep(for: .seconds(3))
        }
        FileHandle.standardError.write("Still pending; re-run to keep waiting.\n"
            .data(using: .utf8)!)
    }
}
