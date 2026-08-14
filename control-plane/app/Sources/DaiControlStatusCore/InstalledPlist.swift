import Foundation

/// What the installer wrote into the daemon's plist.
///
/// The port is not a constant here. `install.sh --port` writes it, so anything
/// hardcoded is wrong on exactly the deployments that changed it - and those are
/// the ones where somebody had a reason. Reading it back means the app follows
/// the installer instead of agreeing with it by coincidence.
public enum InstalledPlist {
    /// The port the control plane was installed to serve on, or the default.
    ///
    /// Takes bytes rather than a path so the parsing can be tested without a
    /// control plane having to be installed on the machine running the tests.
    public static func port(from data: Data?) -> Int {
        guard let data,
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any],
              let env = plist["EnvironmentVariables"] as? [String: Any]
        else { return 8452 }

        // launchd environment values are strings. A number here would be a
        // malformed plist, but tolerating one costs nothing, and an app that
        // cannot find the control plane is worse than a loose parser.
        if let s = env["PORT"] as? String, let p = Int(s), (1...65535).contains(p) { return p }
        if let n = env["PORT"] as? Int, (1...65535).contains(n) { return n }
        return 8452
    }
}
