import Foundation
import Testing
@testable import DaiAgent

/// What a machine reports having on disk.
///
/// The distinction this exists to keep is between holding weights and having
/// them loaded. orca had eighteen gigabytes on disk and reported holding
/// nothing, because the only thing anybody reported was memory residency, and
/// the fleet view agreed with it. An operator acting on that would have sent
/// the same weights over the network to the machine that already had them.
struct StoredModelsTests {
    /// A model directory in the layout swift-transformers actually writes.
    private func makeTree(_ build: (URL) throws -> Void) rethrows -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dai-stored-\(UUID().uuidString)")
        let models = base.appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try build(models)
        return base
    }

    private func write(_ dir: URL, _ name: String, bytes: Int) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path,
                                       contents: Data(count: bytes))
    }

    @Test("finds models in org/repo form")
    func findsOrgRepoModels() throws {
        // Not the models--org--repo form the Python hub client uses. Copying a
        // Python cache into this directory produces something that looks right
        // and is never found, which has already happened once.
        let base = makeTree { models in
            write(models.appendingPathComponent("mlx-community/Qwen2.5-Coder-32B-Instruct-4bit"),
                  "model-00001.safetensors", bytes: 1024)
        }
        defer { try? FileManager.default.removeItem(at: base) }

        let found = StoredModels.scan(base: base)
        #expect(found.keys.contains("mlx-community/Qwen2.5-Coder-32B-Instruct-4bit"))
    }

    @Test("reports size across every file in the model")
    func sumsAllShards() throws {
        // A model is four shards plus a tokenizer. Reporting one file's size,
        // or the directory entry's, would understate storage by an order of
        // magnitude.
        let base = makeTree { models in
            let dir = models.appendingPathComponent("org/model")
            write(dir, "shard-1.safetensors", bytes: 512 * 1024)
            write(dir, "shard-2.safetensors", bytes: 512 * 1024)
            write(dir, "tokenizer.json", bytes: 1024)
        }
        defer { try? FileManager.default.removeItem(at: base) }

        let gb = StoredModels.scan(base: base)["org/model"] ?? 0
        #expect(gb > 0.00097 && gb < 0.00101, "expected about 1MiB, got \(gb)GB")
    }

    @Test("finds Core ML packages, which are not in org/repo form")
    func findsCoreMLPackages() throws {
        // The ANE model sits directly under the root as a bundle. Scanning only
        // for org/repo would report an ANE-only machine as holding nothing,
        // which is every small machine in the fleet.
        let base = makeTree { models in
            write(models.appendingPathComponent("ane_embed.mlpackage"), "model.mlmodel", bytes: 512)
        }
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(StoredModels.scan(base: base)["ane:embed"] != nil)
    }

    @Test("does not report the inside of a bundle as a model")
    func doesNotDescendIntoBundles() throws {
        // An .mlpackage is a directory, so the org/repo walk went into it and
        // announced "ane_embed.mlpackage/Data" as a model the fleet held. The
        // catalogue can never match that to anything, so it would sit in the
        // list forever as weights nobody can account for.
        let base = makeTree { models in
            write(models.appendingPathComponent("ane_embed.mlpackage/Data/com.apple.CoreML"),
                  "model.mlmodel", bytes: 512)
        }
        defer { try? FileManager.default.removeItem(at: base) }

        let found = StoredModels.scan(base: base)
        #expect(found["ane:embed"] != nil)
        #expect(found.keys.allSatisfy { !$0.contains(".mlpackage") },
                "reported bundle internals: \(found.keys.sorted())")
    }

    @Test("reports nothing rather than failing when there is no model directory")
    func missingDirectoryIsEmpty() {
        // A fresh machine, or one whose FileVault volume has not mounted. This
        // has to be an empty answer and not a crash in the heartbeat path.
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dai-absent-\(UUID().uuidString)")
        #expect(StoredModels.scan(base: base).isEmpty)
    }

    @Test("does not mistake a loose file for a model")
    func ignoresStrayFiles() throws {
        // The directory accumulates things: a partial download, a note, a
        // .DS_Store. Any of them announced as a model would show up in the
        // catalogue as weights nobody can account for.
        let base = makeTree { models in
            FileManager.default.createFile(atPath: models.appendingPathComponent("README").path,
                                           contents: Data(count: 10))
            write(models.appendingPathComponent("org/real"), "weights.safetensors", bytes: 64)
        }
        defer { try? FileManager.default.removeItem(at: base) }

        let found = StoredModels.scan(base: base)
        #expect(found.count == 1)
        #expect(found["org/real"] != nil)
    }
}
