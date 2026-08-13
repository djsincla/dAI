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
