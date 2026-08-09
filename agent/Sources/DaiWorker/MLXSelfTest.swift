import MLX

/// Forces MLX to initialise its Metal shader library.
///
/// Separate from the runtime because it has to be callable from a process whose
/// only job is to find out whether that initialisation survives. On a machine
/// without the Metal toolchain it does not, and the failure is a C++ abort
/// rather than an error anyone can catch.
public enum MLXSelfTest {
    public static func touchGPU() {
        // Float explicitly. A Swift literal array is [Double], and Metal has no
        // float64, so the obvious spelling fails on a working GPU with an error
        // about dtypes that reads like a broken installation.
        //
        // Small enough to be free, real enough that the shaders must load: an
        // allocation alone would not, but an evaluated op will.
        let a = MLXArray([Float(1), Float(2), Float(3)])
        let b = a + a
        b.eval()
    }
}
