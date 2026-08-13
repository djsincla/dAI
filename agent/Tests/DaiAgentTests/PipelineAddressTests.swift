import Foundation
import Testing
@testable import DaiAgent

/// Which address a peer should dial to reach this machine.
///
/// Not the one the control plane sees. E7 ran the pipeline over a Thunderbolt
/// bridge while both machines reached the control plane over the ordinary LAN,
/// so the source address of a heartbeat is the wrong answer - it sends a dialer
/// down the slow path, or to somewhere the peer cannot reach at all.
struct PipelineAddressTests {
    @Test("an explicit address is used exactly as given")
    func explicitWins() {
        // Somebody who has cabled two machines together and says so is not
        // guessing, and should not be second-guessed.
        #expect(PipelineAddress.current(environment: ["DAI_PIPELINE_ADDRESS": "192.168.99.1"])
                == "192.168.99.1")
    }

    @Test("blank is treated as unset rather than as an address")
    func blankIsUnset() {
        // An empty environment variable is what a template renders when nobody
        // filled it in, and advertising "" would be a dial that fails oddly.
        let got = PipelineAddress.current(environment: ["DAI_PIPELINE_ADDRESS": "   "])
        #expect(got != "")
        #expect(got != "   ")
    }

    @Test("a Thunderbolt bridge is preferred over ordinary interfaces")
    func bridgeFirst() {
        // Somebody cabled the machines together for this. E7 measured Wi-Fi at
        // ~70ms round trip against 0.48ms wired, and a pipeline pays it per token.
        #expect(PipelineAddress.rank("bridge0") < PipelineAddress.rank("en0"))
        #expect(PipelineAddress.rank("en0") < PipelineAddress.rank("wat0"))
    }

    @Test("a cabled bridge beats a virtual one")
    func jumboFramesWin() {
        // Real hardware found this immediately. rotorua has four bridges:
        // bridge0 is the Thunderbolt link and bridge100/101/102 are
        // virtualisation networks no peer can reach. Preferring the first
        // bridge returned was right there by accident, and MTU is the property
        // that actually separates them - Thunderbolt runs 9000, a virtual
        // switch runs 1500.
        let found = [("bridge100", "192.168.64.1"), ("bridge0", "192.168.99.1"),
                     ("en0", "192.168.4.24")]
        let mtu = ["bridge0": 9000, "bridge100": 1500, "en0": 1500]
        #expect(PipelineAddress.ordered(found, mtu: mtu).first?.address == "192.168.99.1")
    }

    @Test("a bridge still beats Ethernet when nothing has jumbo frames")
    func kindBeforeSize() {
        let found = [("en0", "192.168.4.24"), ("bridge0", "192.168.99.1")]
        let mtu = ["bridge0": 1500, "en0": 1500]
        #expect(PipelineAddress.ordered(found, mtu: mtu).first?.address == "192.168.99.1")
    }

    @Test("the order does not depend on which interface was seen first")
    func stableOrder() {
        // The bug this replaces: getifaddrs order deciding what a machine
        // advertises.
        let mtu = ["bridge0": 9000, "bridge100": 1500]
        let a = PipelineAddress.ordered(
            [("bridge0", "1.1.1.1"), ("bridge100", "2.2.2.2")], mtu: mtu)
        let b = PipelineAddress.ordered(
            [("bridge100", "2.2.2.2"), ("bridge0", "1.1.1.1")], mtu: mtu)
        #expect(a.map(\.address) == b.map(\.address))
    }

    @Test("this machine advertises something a peer could dial")
    func findsSomething() {
        // Not asserting a particular address - it differs per machine - but a
        // node with no answer here cannot join a split at all, and finding that
        // out at dispatch is too late.
        let found = PipelineAddress.addresses()
        #expect(!found.isEmpty)
        for (_, address) in found {
            #expect(!address.hasPrefix("127."))
            #expect(!address.hasPrefix("169.254."))
        }
    }
}
