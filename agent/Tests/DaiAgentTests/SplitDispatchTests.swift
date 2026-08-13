import Foundation
import Testing
@testable import DaiAgent
@testable import DaiWorker

/// Reading the plan the control plane sends each rank.
///
/// Every field is required rather than defaulted, because a split that starts
/// with half a plan is a pipeline that hangs. A default here would turn a
/// control plane sending the wrong shape into a machine waiting quietly for a
/// peer that was never told to come.
struct SplitDispatchTests {
    private func body(_ split: [String: JSONValue]) -> JSONValue {
        .object(["messages": .array([]), "split": .object(split)])
    }

    private var listener: [String: JSONValue] {
        ["rank": .number(0), "size": .number(2), "role": .string("listen"),
         "port": .number(7710), "model": .string("org/model")]
    }

    private var dialer: [String: JSONValue] {
        ["rank": .number(1), "size": .number(2), "role": .string("dial"),
         "port": .number(7710), "model": .string("org/model"),
         "peer": .string("192.168.99.1")]
    }

    @Test("an ordinary completion is not a split")
    func plainRequest() {
        // The common case, and it has to stay cheap: every dispatch passes
        // through here.
        #expect(SplitDispatch(body: .object(["messages": .array([])])) == nil)
    }

    @Test("the rank that listens is told to listen")
    func readsListener() throws {
        let split = try #require(SplitDispatch(body: body(listener)))
        #expect(split.rank == 0)
        #expect(split.role == .listen)
        #expect(split.peer == nil)
        #expect(split.port == 7710)
    }

    @Test("the rank that dials is told where")
    func readsDialer() throws {
        let split = try #require(SplitDispatch(body: body(dialer)))
        #expect(split.role == .dial)
        #expect(split.peer == "192.168.99.1")
    }

    @Test("a dialer with nowhere to dial is refused")
    func dialerNeedsAPeer() {
        // The difference between a clear failure and a stalled gang. Without
        // this the machine starts, finds no peer, and waits.
        var without = dialer
        without["peer"] = nil
        #expect(SplitDispatch(body: body(without)) == nil)

        var empty = dialer
        empty["peer"] = .string("")
        #expect(SplitDispatch(body: body(empty)) == nil)
    }

    @Test("a role nobody recognises is refused rather than guessed")
    func unknownRole() {
        // Roles are named rather than inferred from rank so that renumbering
        // cannot silently change who listens. An unrecognised one has to fail.
        var odd = listener
        odd["role"] = .string("whatever")
        #expect(SplitDispatch(body: body(odd)) == nil)
    }

    @Test("a plan missing any field is refused")
    func everyFieldRequired() {
        for missing in ["rank", "size", "role", "port", "model"] {
            var partial = listener
            partial[missing] = nil
            #expect(SplitDispatch(body: body(partial)) == nil,
                    "a plan without \(missing) should not start a rank")
        }
    }
}
