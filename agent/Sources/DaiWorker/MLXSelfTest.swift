import MLX

/// Forces MLX to initialise its Metal shader library.
///
/// Separate from the runtime because it has to be callable from a process whose
/// only job is to find out whether that initialisation survives. On a machine
/// without the Metal toolchain it does not, and the failure is a C++ abort
/// rather than an error anyone can catch.
public enum MLXSelfTest {
    public static func touchGPU() {
        // Small enough to be free, real enough that the shaders must load: an
        // allocation alone would not, but an evaluated op will.
        let a = MLXArray([1.0, 2.0, 3.0])
        let b = a + a
        b.eval()
    }
}
