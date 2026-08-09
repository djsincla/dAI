import Foundation
import IOKit

/// A stable identifier for this physical machine.
///
/// Enrollment mints a new key and a new node record every time it runs, and
/// nothing tied those records to the hardware. So a machine reinstalled, or
/// re-enrolled after its identity was purged, appeared as a second node: the old
/// record stayed active-looking forever, inflating the fleet view and the
/// capacity figures with a machine that no longer existed. Over a fleet that
/// compounds, and the numbers people are asked to trust drift away from the
/// hardware they describe.
///
/// `IOPlatformUUID` survives reinstalls and OS upgrades and is unique per
/// machine, which is exactly the property needed. It is not a secret and is not
/// treated as one: it identifies which record a re-enrollment replaces, and
/// authentication remains the certificate.
public enum MachineIdentity {
    public static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0) else { return nil }
        return value.takeRetainedValue() as? String
    }
}
