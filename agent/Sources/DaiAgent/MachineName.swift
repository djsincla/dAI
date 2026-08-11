import Foundation
import SystemConfiguration

/// What to call this machine in the fleet.
///
/// macOS offers three names and they are not equally trustworthy, which is not
/// obvious until a daemon picks the wrong one. orca enrolled as
/// `syn-2600-6c52-7e3f-928c-1471-1de5-6613-f136`: `ProcessInfo.hostName` early
/// in boot is whatever reverse DNS says, and before the Bonjour `.local` name
/// is applied that is the machine's own public IPv6 address with the colons
/// swapped for dashes. By the time anyone logs in to check, the same call
/// returns `orca.local` and the evidence is gone.
///
/// Three reasons that matters more than a cosmetic label:
///
/// **The fleet view is how an operator identifies a machine.** A name nobody
/// recognises makes "which one is slow" unanswerable.
///
/// **It is read once, at enrolment.** A machine that joins under the wrong name
/// keeps it, so a transient boot-order condition becomes permanent.
///
/// **It puts a public address in the database and on screen.** That is a
/// routable address for a machine inside the building, recorded in a system
/// whose entire premise is that data does not leave.
///
/// So prefer the names a person actually set, and treat the reverse-DNS one as
/// a last resort that gets checked before it is believed.
public enum MachineName {
    /// The name to enrol under, read from this machine.
    public static func current() -> String {
        choose(localHostName: SCDynamicStoreCopyLocalHostName(nil) as String?,
               computerName: SCDynamicStoreCopyComputerName(nil, nil) as String?,
               processHostName: ProcessInfo.processInfo.hostName)
    }

    /// The choice itself, separated from the machine so it can be tested.
    ///
    /// `localHostName` is the Bonjour name from Sharing preferences - stored on
    /// disk, set by a person, independent of the network. `computerName` is the
    /// friendly name, which may contain spaces and by default is a model
    /// description rather than a name ("MacBook Pro (8)"), so it is a fallback
    /// and not a first choice. `processHostName` comes from the resolver and is
    /// only trusted if it does not look like an address.
    public static func choose(localHostName: String?, computerName: String?,
                              processHostName: String?) -> String {
        if let name = clean(localHostName) { return name }
        if let name = clean(processHostName) { return name }
        // Below the resolver name because it is a description by default, but
        // above giving up: a machine called "MacBook Pro (8)" is at least a
        // machine somebody could point at.
        if let name = clean(computerName, allowAddressLike: true) { return name }
        return "node"
    }

    private static func clean(_ raw: String?, allowAddressLike: Bool = false) -> String? {
        guard let short = raw?.components(separatedBy: ".").first?
            .trimmingCharacters(in: .whitespaces), !short.isEmpty else { return nil }
        if !allowAddressLike && looksLikeAddress(short) { return nil }
        return short
    }

    /// Whether a name is really an address wearing a hostname's clothes.
    ///
    /// Reverse DNS renders an IPv6 address as its hex groups joined by dashes,
    /// usually behind a provider's prefix. Requiring four such groups keeps
    /// ordinary names safe - `mac-1234` has one, `studio-01` none - while
    /// catching the eight-group form that started this.
    static func looksLikeAddress(_ name: String) -> Bool {
        let hexGroups = name.components(separatedBy: "-").filter { part in
            part.count == 4 && part.allSatisfy(\.isHexDigit)
        }
        return hexGroups.count >= 4
    }
}
