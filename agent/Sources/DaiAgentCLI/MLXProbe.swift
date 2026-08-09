import DaiWorker
import Foundation

/// Decides whether MLX can actually run on this machine, without risking the
/// agent if it cannot.
///
/// MLX needs a Metal shader library compiled by a toolchain that is a separate
/// Xcode download, and when it is missing MLX does not throw. It prints
/// "Failed to load the default metallib" from C++ and takes the process with
/// it, which is not something a Swift `do/catch` can contain. An agent that
/// dies this way stops doing ANE work too, and ANE work is the only thing three
/// of the five presence states permit at all.
///
/// So the check runs in a child process. If MLX aborts, it aborts there.
enum MLXProbe {
    /// The subcommand the child runs. Kept trivial on purpose: it has to touch
    /// the GPU enough to force the shader library to load, and do nothing else
    /// that could fail for an unrelated reason.
    static func runChild() -> Int32 {
        MLXSelfTest.touchGPU()
        print("ok")
        return 0
    }

    static func isAvailable() -> Bool {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["verify-mlx-child"]
        let out = Pipe()
        child.standardOutput = out
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8) ?? ""
            child.waitUntilExit()
            return child.terminationStatus == 0 && text.contains("ok")
        } catch {
            return false
        }
    }
}
