import Foundation
import Testing
@testable import DaiAgent

/// Which of the three names macOS offers a machine should enrol under.
///
/// orca joined the fleet as `syn-2600-6c52-7e3f-928c-1471-1de5-6613-f136` - its
/// own public IPv6 address, because a daemon starting before the Bonjour name
/// is applied gets whatever reverse DNS says. The name is read once at
/// enrolment, so that stuck, and it is the only label an operator has for
/// telling one machine from another.
struct MachineNameTests {
    @Test("prefers the name somebody set")
    func prefersLocalHostName() {
        #expect(MachineName.choose(localHostName: "orca",
                                   computerName: "MacBook Pro (8)",
                                   processHostName: "orca.local") == "orca")
    }

    @Test("drops the domain")
    func stripsDomain() {
        #expect(MachineName.choose(localHostName: nil, computerName: nil,
                                   processHostName: "studio-01.lan") == "studio-01")
    }

    @Test("refuses a name that is really an address")
    func rejectsAddressDerivedName() {
        // The exact name orca enrolled under. Falling through to the computer
        // name gives something a person can recognise, which is the whole job.
        let name = MachineName.choose(
            localHostName: nil, computerName: "orca",
            processHostName: "syn-2600-6c52-7e3f-928c-1471-1de5-6613-f136")
        #expect(name == "orca")
    }

    @Test("keeps ordinary names that happen to contain hex")
    func keepsOrdinaryNames() {
        // The check has to be narrow: a rule that rejects real names would send
        // machines to the fallback and make every one of them look alike.
        for name in ["mac-1234", "studio-01", "edit-bay-3", "beef-cafe", "rotorua"] {
            #expect(MachineName.looksLikeAddress(name) == false, "rejected \(name)")
        }
        #expect(MachineName.looksLikeAddress("2600-6c52-7e3f-928c-1471-1de5-6613-f136"))
    }

    @Test("always answers with something")
    func alwaysReturnsAName() {
        // Enrolment cannot proceed without a subject, and an empty one would
        // fail inside CSR generation rather than here.
        #expect(MachineName.choose(localHostName: nil, computerName: nil,
                                   processHostName: nil) == "node")
        #expect(MachineName.choose(localHostName: "  ", computerName: "",
                                   processHostName: nil) == "node")
    }

    @Test("reads a real name from this machine")
    func readsThisMachine() {
        // Guards the SystemConfiguration call itself, which the pure chooser
        // cannot reach: a nil bridge here would send every machine to "node".
        let name = MachineName.current()
        #expect(!name.isEmpty)
        #expect(name != "node")
        #expect(!MachineName.looksLikeAddress(name))
    }
}
