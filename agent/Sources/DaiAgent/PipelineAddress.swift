import Foundation

/// The address a peer should dial to reach this machine for pipeline traffic.
///
/// Not the address the control plane sees. A split runs over whatever link the
/// two machines share, and that is deliberately not always the one they use to
/// reach the control plane: E7 ran the pipeline over a Thunderbolt bridge on
/// 192.168.99.x while both machines talked to the control plane over the
/// ordinary LAN. Handing a dialer the source address of a heartbeat would send
/// it down the slow path, or to an address the peer cannot reach at all.
///
/// So the node declares it. Only the node knows which of its interfaces is the
/// one it shares with its peers, and on a machine with a Thunderbolt bridge,
/// Wi-Fi and Ethernet the answer is not guessable from outside.
///
/// `DAI_PIPELINE_ADDRESS` names it outright, for the case where somebody has
/// built a dedicated link and wants it used. Absent that, the first non-loopback
/// IPv4 address is a reasonable guess and a wrong one is visible immediately -
/// the dial fails rather than silently taking a slower route.
public enum PipelineAddress {
    /// What to advertise, or nil when this machine has no usable address.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let declared = environment["DAI_PIPELINE_ADDRESS"],
           !declared.trimmingCharacters(in: .whitespaces).isEmpty {
            return declared.trimmingCharacters(in: .whitespaces)
        }
        return firstUsableIPv4()
    }

    /// Interfaces in the order they are worth trying.
    ///
    /// A Thunderbolt bridge appears as `bridge*`, and it is preferred when
    /// present because somebody who has cabled two machines together did it for
    /// this. Then wired, then wireless: E7 measured Wi-Fi at ~70 ms round trip
    /// against 0.48 ms wired, and a pipeline pays that per token.
    static let preference = ["bridge", "en", "utun"]

    static func rank(_ name: String) -> Int {
        for (i, prefix) in preference.enumerated() where name.hasPrefix(prefix) {
            return i
        }
        return preference.count
    }

    /// Every non-loopback IPv4 address this machine has, best first.
    static func addresses() -> [(interface: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [(String, String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                 &host, socklen_t(host.count),
                                 nil, 0, NI_NUMERICHOST)
            guard ok == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            let text = String(cString: host)
            // Link-local is not routable to a peer and is what a machine reports
            // when DHCP has not answered. Advertising one produces a dial that
            // fails in a way that looks like the peer is down.
            guard !text.hasPrefix("169.254.") else { continue }
            found.append((name, text))
        }
        return found.sorted { rank($0.0) < rank($1.0) }
    }

    static func firstUsableIPv4() -> String? { addresses().first?.address }
}
