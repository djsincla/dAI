import Foundation

/// Process quality of service.
///
/// E1 measured `ProcessType: Background` costing ~2.4x GPU throughput on a
/// sustained matmul loop, which made it look like a modest politeness tax. The
/// harvest worker later measured **~26x on bursty work** (0.136s per item
/// against 3.528s), because each item is a short burst with CPU work between GPU
/// submissions and macOS deschedules the process in those gaps.
///
/// That difference is the whole reason this is dynamic rather than set once in a
/// plist. Two rules follow from it:
///
/// - Promote to standard the moment nobody can see the screen. Leaving it pinned
///   to background wastes most of the overnight window.
/// - Never apply background QoS to ANE work. E5 measured that as
///   indistinguishable from no load, so there is nothing to be polite about, and
///   paying 26x buys politeness that is already free. That bug cost 50x
///   throughput in the Python agent before it was found.
public enum ProcessQoS {
    // setpriority(2) with Darwin extensions. Callable on self, which is what
    // lets QoS follow presence at runtime instead of being fixed at launch.
    private static let prioDarwinProcess: Int32 = 4
    private static let prioDarwinBackground: Int32 = 0x1000

    @discardableResult
    public static func setBackground(_ enabled: Bool) -> Bool {
        setpriority(prioDarwinProcess, 0, enabled ? prioDarwinBackground : 0) == 0
    }

    /// QoS for a specific piece of work.
    ///
    /// ANE work always runs at standard priority regardless of what the presence
    /// policy says, because the policy's QoS field exists to protect the user
    /// from GPU contention and ANE work does not create any.
    public static func apply(policy: StatePolicy, kind: WorkKind) {
        setBackground(policy.qos == .background && kind.isGPU)
    }
}
