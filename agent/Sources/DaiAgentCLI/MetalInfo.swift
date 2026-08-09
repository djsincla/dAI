import Metal

/// Metal caps itself well below installed memory, around 81% on an M2 Max. Agent
/// ceilings are fractions of *this*, never of installed RAM, so the control
/// plane needs it at enrollment.
enum MetalInfo {
    static func workingSetGb() -> Double {
        guard let device = MTLCreateSystemDefaultDevice() else { return 0 }
        return Double(device.recommendedMaxWorkingSetSize) / 1_073_741_824
    }
}
