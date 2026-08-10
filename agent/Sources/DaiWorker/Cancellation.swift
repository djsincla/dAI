import Foundation

/// A flag the generation loop can read without awaiting anything.
///
/// Generation runs inside `ModelContainer.perform`, which is synchronous from
/// the loop's point of view: there is nowhere to await a cancellation, so it has
/// to be a value that can be read between tokens. A lock rather than an actor
/// for exactly that reason.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}
