import Testing
@testable import DaiControlStatusCore
import Foundation

/// Reading the port back out of the daemon's plist.
///
/// The shape below is the installed one on this desk, with the database
/// credential replaced - a real DATABASE_URL is in that file and does not belong
/// in a repository. What is being tested is the path to PORT, and that is
/// identical either way.
@Suite("the port the installer chose")
struct InstalledPlistTests {
    static func plist(port: String?) -> Data {
        let portEntry = port.map { "<key>PORT</key><string>\($0)</string>" } ?? ""
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>com.dai.control</string>
          <key>EnvironmentVariables</key>
          <dict>
            <key>DATABASE_URL</key><string>postgres://user:pass@localhost:5433/dai</string>
            \(portEntry)
            <key>TLS_CERT</key><string>/var/db/dai-control/certs/server.crt</string>
          </dict>
          <key>StandardOutPath</key><string>/var/log/dai-control/control.log</string>
        </dict>
        </plist>
        """.utf8)
    }

    @Test("follows the installer rather than agreeing with it by coincidence")
    func reads() {
        #expect(InstalledPlist.port(from: Self.plist(port: "8452")) == 8452)
        // The case that matters: a deployment that chose something else. A
        // hardcoded default would look right here and be wrong there.
        #expect(InstalledPlist.port(from: Self.plist(port: "9443")) == 9443)
    }

    @Test("falls back rather than failing")
    func fallback() {
        // No plist at all is the not-installed case, where the app has nothing
        // to talk to anyway and the number is never used.
        #expect(InstalledPlist.port(from: nil) == 8452)
        #expect(InstalledPlist.port(from: Self.plist(port: nil)) == 8452)
        #expect(InstalledPlist.port(from: Data("not a plist".utf8)) == 8452)
    }

    @Test("refuses a port that is not one")
    func nonsense() {
        #expect(InstalledPlist.port(from: Self.plist(port: "0")) == 8452)
        #expect(InstalledPlist.port(from: Self.plist(port: "99999")) == 8452)
        #expect(InstalledPlist.port(from: Self.plist(port: "eight")) == 8452)
    }
}
