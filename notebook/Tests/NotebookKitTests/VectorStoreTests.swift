import Foundation
import Testing
@testable import NotebookKit

/// The store, and the parts of it that fail without saying so.
///
/// A vector written wrongly is still a blob of the right length. It reads back
/// as numbers, scores as a cosine, ranks the corpus as noise, and nothing
/// raises. So these test the byte layout and the refusals rather than the
/// arithmetic, which is the same reason the agent's embedding tests are shaped
/// the way they are.
struct VectorStoreTests {

    static func temporary(_ name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notebookkit-\(name)")
    }

    @Test("a float survives the round trip byte for byte")
    func vectorRoundTrip() {
        let original: [Float] = [0, 1, -1, 0.5, -0.001, 3.4028235e38, 1.1754944e-38]
        let blob = VectorStore.blob(from: original)
        #expect(blob.count == original.count * 4)
        #expect(VectorStore.vector(from: blob) == original)
    }

    @Test("the layout is little endian float32, which is what numpy writes")
    func vectorLayoutMatchesNumpy() {
        // numpy: np.array([1.0], dtype=np.float32).tobytes() == b'\\x00\\x00\\x80?'
        // Checked as bytes rather than by round tripping, because a round trip
        // through the same wrong code agrees with itself.
        #expect(Array(VectorStore.blob(from: [1.0])) == [0x00, 0x00, 0x80, 0x3F])
        #expect(Array(VectorStore.blob(from: [-2.0])) == [0x00, 0x00, 0x00, 0xC0])
    }

    @Test("chunks come back in score order, capped per section")
    func searchRanksAndCaps() async throws {
        let store = try VectorStore(path: Self.temporary())
        let chunks = [
            VectorStore.Chunk(citation: "A", section: "one", url: "u1", text: "first"),
            VectorStore.Chunk(citation: "A", section: "one", url: "u2", text: "second"),
            VectorStore.Chunk(citation: "A", section: "one", url: "u3", text: "third"),
            VectorStore.Chunk(citation: "B", section: "two", url: "u4", text: "fourth"),
        ]
        // Unit vectors pointing progressively away from the query.
        let vectors: [[Float]] = [[1, 0], [0.9, 0.436], [0.8, 0.6], [0.7, 0.714]]
        try await store.add(chunks, vectors: vectors)

        let hits = try await store.search([1, 0], k: 4, perSection: 2)
        #expect(hits.count == 3, "the third chunk of section one should be capped out")
        #expect(hits.map(\.chunk.text) == ["first", "second", "fourth"])
        #expect(hits[0].score > hits[1].score)
    }

    @Test("a notebook refuses a vector of the wrong width")
    func refusesMixedDimensions() async throws {
        // The failure this catches has no other symptom. A 768 dimension vector
        // in a 1024 dimension notebook scores against every other chunk as
        // though the missing dimensions were zero, and the answer is merely
        // worse.
        let store = try VectorStore(path: Self.temporary())
        let chunk = VectorStore.Chunk(citation: "A", section: "one", url: "u", text: "t")
        try await store.add([chunk], vectors: [[1, 0, 0]])
        await #expect(throws: VectorStore.StoreError.self) {
            try await store.add([chunk], vectors: [[1, 0]])
        }
    }

    @Test("and refuses a batch that disagrees with itself")
    func refusesInconsistentBatch() async throws {
        let store = try VectorStore(path: Self.temporary())
        let chunk = VectorStore.Chunk(citation: "A", section: "one", url: "u", text: "t")
        await #expect(throws: VectorStore.StoreError.self) {
            try await store.add([chunk, chunk], vectors: [[1, 0], [1, 0, 0]])
        }
    }

    @Test("a failed add leaves nothing behind")
    func addIsAtomic() async throws {
        let store = try VectorStore(path: Self.temporary())
        let chunk = VectorStore.Chunk(citation: "A", section: "one", url: "u", text: "t")
        try? await store.add([chunk, chunk], vectors: [[1, 0], [1, 0, 0]])
        #expect(try await store.count() == 0)
    }

    @Test("meta is JSON, because that is how the reference client reads it")
    func metaIsJSON() async throws {
        let store = try VectorStore(path: Self.temporary())
        try await store.setMeta("backend", "mlx")
        try await store.setMeta("chunks", 42)
        // json.loads() on the other side, so a bare string would be invalid.
        #expect(try await store.meta("backend") == "\"mlx\"")
        #expect(try await store.meta("chunks") == "42")
        #expect(try await store.meta("absent") == nil)
    }
}

struct NotebookPackageTests {

    @Test("a new notebook has the shape the format promises")
    func createsThePackage() throws {
        let root = VectorStoreTests.temporary("pkg").appendingPathExtension(
            NotebookPackage.fileExtension)
        let package = try NotebookPackage.create(
            at: root, manifest: .init(name: "Statutes"))
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: package.manifestURL.path))
        #expect(fm.fileExists(atPath: package.originalsURL.path))
        #expect(fm.fileExists(atPath: package.extractedURL.path))
        #expect(package.isValid)
        #expect(try package.manifest().name == "Statutes")
        #expect(try package.manifest().embeddingModel
                == NotebookPackage.Manifest.defaultModel)
    }

    @Test("a notebook without its index is still a notebook")
    func indexIsNotLoadBearing() throws {
        // The index is derived and rebuildable. Requiring it to open a notebook
        // would make the derived half load bearing after all, and a notebook
        // shipped without its vectors is a valid notebook with a rebuild ahead
        // of it.
        let root = VectorStoreTests.temporary("noindex")
        let package = try NotebookPackage.create(at: root, manifest: .init(name: "N"))
        #expect(!FileManager.default.fileExists(atPath: package.indexURL.path))
        #expect(package.isValid)
    }

    @Test("turns append and read back in order")
    func recordAppends() throws {
        let root = VectorStoreTests.temporary("record")
        let package = try NotebookPackage.create(at: root, manifest: .init(name: "N"))
        for i in 1 ... 3 {
            try package.append(.init(question: "q\(i)", answer: "a\(i)",
                                     citations: [], k: 6, hybrid: false,
                                     embeddingModel: "m"))
        }
        let turns = try package.turns()
        #expect(turns.map(\.question) == ["q1", "q2", "q3"])
    }

    @Test("a truncated last line loses one turn, not the record")
    func survivesATornWrite() throws {
        // A process dying mid write is the ordinary way a JSON Lines file ends.
        // Refusing to open the notebook would be a worse answer than losing the
        // turn that was never finished.
        let root = VectorStoreTests.temporary("torn")
        let package = try NotebookPackage.create(at: root, manifest: .init(name: "N"))
        try package.append(.init(question: "kept", answer: "a", citations: [],
                                 k: 6, hybrid: false, embeddingModel: "m"))
        let handle = try FileHandle(forWritingTo: package.recordURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"question":"torn","#.utf8))
        try handle.close()

        let turns = try package.turns()
        #expect(turns.map(\.question) == ["kept"])
    }

    @Test("a turn records the settings, not just the words")
    func turnCarriesTheExperiment() throws {
        // The reason this is a record rather than a transcript: weeks later the
        // question is "what was different about that run", and only these
        // fields can answer it.
        let root = VectorStoreTests.temporary("settings")
        let package = try NotebookPackage.create(at: root, manifest: .init(name: "N"))
        try package.append(.init(
            question: "q", answer: "a",
            citations: [.init(citation: "c", section: "s", url: "u", score: 0.87)],
            k: 8, hybrid: true, embeddingModel: "qwen3",
            answeredBy: "rotorua", presenceState: "LOCKED",
            generationModel: "qwen3-30b", seconds: 2.7))
        let turn = try #require(try package.turns().first)
        #expect(turn.k == 8)
        #expect(turn.hybrid)
        #expect(turn.answeredBy == "rotorua")
        #expect(turn.presenceState == "LOCKED")
        #expect(turn.citations.first?.score == 0.87)
    }
}
