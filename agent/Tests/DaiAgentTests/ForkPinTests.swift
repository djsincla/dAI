import Foundation
import Testing

/// The pinned fork revision, against the one the notices claim.
///
/// dAI and notebookMLX both resolve `djsincla/mlx-swift-examples` for
/// `MLXEmbedders`, and they have to resolve the *same* revision. Two copies at
/// different revisions could pool or normalise differently, so an index built by
/// one would be silently incomparable with a query from the other - and the
/// symptom is a corpus that stops matching queries, which reads as a bad model
/// or a bad import and not as a version skew.
///
/// While the fork was vendored at `agent/vendor/`, agreement was structural:
/// there was one checkout and it could not disagree with itself. Splitting the
/// fork into its own repository replaced that with two pins in two repositories,
/// and nothing in either build fails when they drift.
///
/// A test here cannot read the other repository. What it can do is bind the pin
/// to the revision this repository *says* it uses, in NOTICE and
/// THIRD-PARTY-NOTICES.md. That makes the documented revision trustworthy, and
/// the documented revision is what a person compares across the two - `grep` in
/// each NOTICE, rather than resolving a package to find out.
///
/// So bumping the fork is deliberately three edits: Package.swift, and the two
/// notices. Getting one wrong fails here instead of at some later import.
struct ForkPinTests {
    /// The repository root, from this file rather than the working directory,
    /// which differs between `swift test` and Xcode.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DaiAgentTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // agent
        .deletingLastPathComponent()   // repo root

    static let forkRepository = "djsincla/mlx-swift-examples"

    /// The revision SwiftPM actually resolved, read from Package.resolved.
    static func resolvedRevision() throws -> String {
        let data = try Data(contentsOf: root.appendingPathComponent("agent/Package.resolved"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pins = json?["pins"] as? [[String: Any]] ?? []
        let mine = pins.first {
            (($0["location"] as? String) ?? "").contains(forkRepository)
        }
        let state = mine?["state"] as? [String: Any]
        return (state?["revision"] as? String) ?? ""
    }

    @Test("the resolved fork revision is a full commit sha, not a branch")
    func resolvedIsExact() throws {
        let revision = try Self.resolvedRevision()
        // A range or a branch would let the two repositories drift apart while
        // both still resolving successfully, which is the whole failure.
        #expect(revision.count == 40)
        #expect(revision.allSatisfy { $0.isHexDigit })
    }

    @Test("NOTICE names the revision that is actually pinned")
    func noticeAgrees() throws {
        let revision = try Self.resolvedRevision()
        let notice = try String(contentsOf: Self.root.appendingPathComponent("NOTICE"),
                                encoding: .utf8)
        #expect(notice.contains(revision),
                "NOTICE does not name \(revision); bumping the fork means editing Package.swift, NOTICE and THIRD-PARTY-NOTICES.md together")
    }

    @Test("THIRD-PARTY-NOTICES.md names the revision that is actually pinned")
    func thirdPartyNoticesAgree() throws {
        let revision = try Self.resolvedRevision()
        let notices = try String(
            contentsOf: Self.root.appendingPathComponent("THIRD-PARTY-NOTICES.md"),
            encoding: .utf8)
        #expect(notices.contains(revision))
    }
}
