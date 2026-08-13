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
    ///
    /// Three ways of answering, most certain first.
    ///
    /// **`DAI_PIPELINE_INTERFACE`** names the interface - `bridge0` - and the
    /// address is read from it. This is the one to use. An interface name is
    /// stable in a way an address is not: a link that comes back on a different
    /// address after a reboot or a DHCP lease still has the same name, and a
    /// pinned address would then be advertised long after it stopped being
    /// true.
    ///
    /// **`DAI_PIPELINE_ADDRESS`** names the address outright, for the case where
    /// the right answer is not on an interface this machine can see - a NAT, a
    /// tunnel, a forwarded port.
    ///
    /// **Neither**, and it guesses: bridge before wired before wireless, and
    /// jumbo frames before ordinary ones. The guess is right on this fleet and
    /// is still a guess, which is why naming the interface is worth doing.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let named = environment["DAI_PIPELINE_INTERFACE"]?
            .trimmingCharacters(in: .whitespaces), !named.isEmpty {
            // Nil rather than falling back when the named interface has no
            // address. Somebody who named one meant it, and quietly advertising
            // a different link would be worse than saying nothing: the split
            // would run, slowly, over a path nobody chose.
            return addresses().first { $0.interface == named }?.address
        }
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
    ///
    /// The name alone is not enough, which real hardware showed immediately. A
    /// machine running VMs has several bridges: on rotorua, `bridge0` is the
    /// Thunderbolt link at 192.168.99.1 and `bridge100`, `bridge101`,
    /// `bridge102` are virtualisation networks on 192.168.64.x and 172.16.x
    /// that no peer can reach. Picking the first `bridge` returned happened to
    /// be right there and is right by accident.
    ///
    /// So MTU breaks the tie. A Thunderbolt bridge runs 9000; a virtual one
    /// runs 1500. That is not a naming convention but a property of the link,
    /// and a deliberately built fast path is exactly the thing with jumbo
    /// frames on it.
    static let preference = ["bridge", "en", "utun"]

    static func rank(_ name: String) -> Int {
        for (i, prefix) in preference.enumerated() where name.hasPrefix(prefix) {
            return i
        }
        return preference.count
    }

    /// MTU per interface, which only the link-layer entries carry.
    ///
    /// getifaddrs returns one entry per address family per interface, and
    /// `ifa_data` holds `if_data` only on the AF_LINK one. So the MTUs are
    /// collected in their own pass and joined to the addresses by name.
    static func mtus(from first: UnsafeMutablePointer<ifaddrs>) -> [String: Int] {
        var out: [String: Int] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ptr.pointee.ifa_data else { continue }
            let info = data.assumingMemoryBound(to: if_data.self).pointee
            out[String(cString: ptr.pointee.ifa_name)] = Int(info.ifi_mtu)
        }
        return out
    }

    /// Every non-loopback IPv4 address this machine has, best first.
    static func addresses() -> [(interface: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        let mtu = mtus(from: first)

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
        return ordered(found, mtu: mtu)
    }

    /// Best first, given what was found and how big each link's frames are.
    ///
    /// Separated from the interface walk so the ordering can be tested against
    /// a machine that is not this one. The rule it encodes is not obvious and
    /// was wrong once: kind first, so a bridge beats an Ethernet port; then MTU,
    /// so among bridges the cabled link beats a virtual switch; then name, only
    /// so the answer is stable rather than dependent on enumeration order.
    static func ordered(_ found: [(String, String)],
                        mtu: [String: Int]) -> [(interface: String, address: String)] {
        found.sorted {
            if rank($0.0) != rank($1.0) { return rank($0.0) < rank($1.0) }
            let a = mtu[$0.0] ?? 0, b = mtu[$1.0] ?? 0
            if a != b { return a > b }
            return $0.0 < $1.0
        }
    }

    static func firstUsableIPv4() -> String? { addresses().first?.address }
}
