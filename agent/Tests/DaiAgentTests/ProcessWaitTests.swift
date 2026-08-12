import Foundation
import Testing
@testable import DaiWorker

/// Waiting for a child process, which the agent got wrong for weeks.
///
/// The renderer used `waitUntilExit()` and read its output on the cooperative
/// pool. Both are ordinary Foundation and both are wrong from an actor, and the
/// symptom was not a failing test: it was the whole suite stopping, about one
/// run in five, with the child already exited and reaped.
///
/// `waitUntilExit()` spins a run loop on the calling thread and waits for a
/// source the thread that called `run()` registered. There is an `await`
/// between those two calls in `render`, so the actor can resume on a different
/// thread - and then the wakeup goes to a run loop nobody is spinning and the
/// wait never returns. Nothing about the render is wrong; it depends only on
/// which thread the pool happened to hand back.
///
/// These tests cover the two pieces that replaced it. They are ordering tests
/// rather than timing tests: the race that bit was a delivery arriving on the
/// wrong side of a suspension, so what has to hold is that the exit is
/// delivered exactly once whichever side of the wait it lands on.
struct ProcessWaitTests {
    // MARK: - Exit

    @Test("an exit that has already happened is still delivered to a later waiter")
    func deliversToALateWaiter() async {
        // The dangerous order, and the one a fast child produces: the process is
        // gone before anybody asks. A handler that only ever resumes a
        // continuation it can see would drop this and hang forever, which is the
        // bug this replaced wearing different clothes.
        let exit = RenderRuntime.Exit()
        exit.finished(3)
        #expect(await exit.value == 3)
    }

    @Test("an exit that happens while somebody is waiting wakes them")
    func wakesAWaitingCaller() async {
        let exit = RenderRuntime.Exit()
        async let status = exit.value
        // Not a sleep. The waiter may not have parked yet, and the point is that
        // it does not matter: whichever order these two reach the lock, the
        // value arrives.
        exit.finished(0)
        #expect(await status == 0)
    }

    @Test("many waiters on many exits all come back")
    func doesNotStarveUnderConcurrency() async {
        // More concurrent waits than there are cooperative threads. Under the
        // old code each one held a thread for the life of its child, so a
        // handful of renders could consume the pool the whole agent shares -
        // and a pool with nothing left cannot run the work that would release
        // it. Here nothing blocks, so the count is free to exceed the width.
        let count = 64
        let statuses = await withTaskGroup(of: Int32.self) { group in
            for i in 0..<count {
                group.addTask {
                    let exit = RenderRuntime.Exit()
                    // Half deliver before the wait, half after, so both orders
                    // are exercised under contention rather than in isolation.
                    if i.isMultiple(of: 2) {
                        exit.finished(Int32(i))
                        return await exit.value
                    }
                    async let value = exit.value
                    exit.finished(Int32(i))
                    return await value
                }
            }
            var seen: [Int32] = []
            for await status in group { seen.append(status) }
            return seen
        }
        #expect(statuses.count == count)
        #expect(statuses.sorted() == (0..<count).map(Int32.init))
    }

    // MARK: - draining a pipe

    @Test("the child's output is read to the end")
    func readsEverythingTheChildWrote() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "printf 'one\\ntwo\\nthree\\n'"]
        let out = Pipe()
        child.standardOutput = out

        let exit = RenderRuntime.Exit()
        child.terminationHandler = { exit.finished($0.terminationStatus) }
        try child.run()

        let log = await RenderRuntime.drain(out.fileHandleForReading)
        #expect(await exit.value == 0)
        #expect(log == "one\ntwo\nthree\n")
    }

    @Test("a child that writes more than the pipe holds does not deadlock")
    func survivesMoreOutputThanThePipeBuffers() async throws {
        // The reason the read comes before the wait, and the reason it cannot be
        // the other way round. A pipe buffer is 64KB or so; a real render writes
        // megabytes of progress. Waiting for exit first stops the child on a
        // full pipe while the agent waits for a child that can never finish.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "for i in $(seq 1 20000); do echo 'a line of renderer progress'; done"]
        let out = Pipe()
        child.standardOutput = out

        let exit = RenderRuntime.Exit()
        child.terminationHandler = { exit.finished($0.terminationStatus) }
        try child.run()

        let log = await RenderRuntime.drain(out.fileHandleForReading)
        #expect(await exit.value == 0)
        #expect(log.count > 128 * 1024)
        #expect(RenderRuntime.tail(of: log, lines: 1) == "a line of renderer progress")
    }

    @Test("a child that fails reports its status rather than throwing it away")
    func reportsANonZeroStatus() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "echo 'Error: cannot read scene' >&2; exit 42"]
        let out = Pipe()
        child.standardOutput = out
        child.standardError = out

        let exit = RenderRuntime.Exit()
        child.terminationHandler = { exit.finished($0.terminationStatus) }
        try child.run()

        let log = await RenderRuntime.drain(out.fileHandleForReading)
        #expect(await exit.value == 42)
        #expect(RenderRuntime.tail(of: log).contains("cannot read scene"))
    }

    @Test("several children waited on at once all come back")
    func waitsOnManyChildrenAtOnce() async throws {
        // The shape `render` is called in when a machine has more than one unit
        // in flight, and the shape that used to starve the pool. Each child
        // sleeps, so all of them are alive at the same time and every wait is
        // outstanding at once.
        let statuses = try await withThrowingTaskGroup(of: Int32.self) { group in
            for i in 0..<24 {
                group.addTask {
                    let child = Process()
                    child.executableURL = URL(fileURLWithPath: "/bin/sh")
                    child.arguments = ["-c", "sleep 0.3; exit \(i % 5)"]
                    child.standardOutput = FileHandle.nullDevice
                    let exit = RenderRuntime.Exit()
                    child.terminationHandler = { exit.finished($0.terminationStatus) }
                    try child.run()
                    return await exit.value
                }
            }
            var seen: [Int32] = []
            for try await status in group { seen.append(status) }
            return seen
        }
        #expect(statuses.count == 24)
        #expect(statuses.sorted() == (0..<24).map { Int32($0 % 5) }.sorted())
    }
}
