import DaiAgent
import Foundation

/// Enrollment, kept separate because it happens once and needs a human in the
/// middle: a join token gets a node into a queue, an admin decides whether it
/// becomes a member.
///
/// The private key is generated here and never sent anywhere. The production
/// target is the Secure Enclave with the key marked non-exportable, so a
/// certificate copied off disk is useless without the hardware; this writes a
/// 0600 file, which is the weaker of the two and is why it is called out.
enum Enroll {
    static func identityDir() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dai/identity")
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

    static func generateCSR(dir: URL, commonName: String) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = dir.appendingPathComponent("node.key")
        let csr = dir.appendingPathComponent("node.csr")

        if !FileManager.default.fileExists(atPath: key.path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            // The CN here is ignored by the issuer: the control plane names the
            // certificate after the node record, so a machine cannot request an
            // identity belonging to another node.
            p.arguments = ["req", "-newkey", "rsa:2048", "-nodes",
                           "-keyout", key.path, "-out", csr.path, "-subj", "/CN=\(commonName)"]
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        }
        return try String(contentsOf: csr, encoding: .utf8)
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
        let ca = try caPath.map { try ClientIdentity.loadCA(pem: URL(fileURLWithPath: $0)) }
        let cp = ControlPlane(base: controlPlane, identity: nil, serverCA: ca)

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
