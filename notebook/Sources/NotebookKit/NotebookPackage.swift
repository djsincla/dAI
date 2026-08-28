import Foundation

/// A notebook on disk: a directory the Finder presents as one file.
///
///     Statutes.dainotebook/
///       notebook.json     name, embedding model, chunk settings
///       index.sqlite      chunks and vectors, in rag_store.py's schema
///       originals/        what was dropped in, byte for byte
///       extracted/        the text each original produced
///       record.jsonl      one line per exchange
///
/// **Two kinds of content, and they are not equally valuable.** `originals/`
/// and `record.jsonl` are the work: unrecoverable if lost. `extracted/` and
/// `index.sqlite` are derived, rebuildable from the originals in minutes, and
/// saying so is what makes a corrupt index discardable rather than a
/// catastrophe, a notebook shippable without its vectors, and a change of
/// embedding model a rebuild rather than a migration.
///
/// The record is JSON Lines rather than a table. It is append only, it survives
/// a process dying mid write with the loss of at most the last line, and it can
/// be read by anything. A conversation is the one part of a notebook somebody
/// might want to grep.
public struct NotebookPackage: Sendable {
    public let root: URL

    public var manifestURL: URL { root.appendingPathComponent("notebook.json") }
    public var indexURL: URL { root.appendingPathComponent("index.sqlite") }
    public var originalsURL: URL { root.appendingPathComponent("originals") }
    public var extractedURL: URL { root.appendingPathComponent("extracted") }
    public var recordURL: URL { root.appendingPathComponent("record.jsonl") }

    public static let fileExtension = "dainotebook"

    public init(root: URL) { self.root = root }

    // ------------------------------------------------------------ manifest

    /// What produced this notebook's vectors, and how.
    ///
    /// Recorded rather than assumed, and checked before a query. Two embedding
    /// models means two coordinate systems: vectors from one scored against
    /// vectors from the other are the right length, in the right range,
    /// comparable by cosine, and rank the corpus as noise. Nothing raises. It
    /// is the failure this whole area keeps producing, so the model that made
    /// the vectors travels with them.
    public struct Manifest: Codable, Sendable, Equatable {
        public var name: String
        public var embeddingModel: String
        public var dimensions: Int?
        public var chunkChars: Int
        public var overlap: Int
        public var createdAt: Date
        /// Whether the vectors were made here or by the fleet. Not a
        /// correctness property, since the two agree to 0.9998 cosine and
        /// reproduce each other's ranking, but worth knowing when a notebook
        /// behaves oddly.
        public var embeddedBy: String

        public init(name: String,
                    embeddingModel: String = Manifest.defaultModel,
                    dimensions: Int? = nil,
                    chunkChars: Int = 600, overlap: Int = 100,
                    createdAt: Date = Date(),
                    embeddedBy: String = "local") {
            self.name = name
            self.embeddingModel = embeddingModel
            self.dimensions = dimensions
            self.chunkChars = chunkChars
            self.overlap = overlap
            self.createdAt = createdAt
            self.embeddedBy = embeddedBy
        }

        /// The model both implementations run and the only architecture Swift
        /// MLXEmbedders and Python mlx-embeddings both support with room for a
        /// whole section. See docs/EMBEDDINGS_PLAN.md.
        public static let defaultModel = "mlx-community/Qwen3-Embedding-0.6B-8bit"
    }

    // ------------------------------------------------------------ creating

    @discardableResult
    public static func create(at root: URL, manifest: Manifest) throws -> NotebookPackage {
        let fm = FileManager.default
        let package = NotebookPackage(root: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: package.originalsURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: package.extractedURL, withIntermediateDirectories: true)
        try package.write(manifest)
        if !fm.fileExists(atPath: package.recordURL.path) {
            fm.createFile(atPath: package.recordURL.path, contents: Data())
        }
        return package
    }

    public func write(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    public func manifest() throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
    }

    /// Whether this looks like a notebook rather than any other directory.
    ///
    /// The index is deliberately not required. A notebook shipped without its
    /// vectors is a valid notebook with a rebuild ahead of it, and refusing to
    /// open one would make the derived half load bearing after all.
    public var isValid: Bool {
        FileManager.default.fileExists(atPath: manifestURL.path)
    }

    // ------------------------------------------------------------ the record

    /// One exchange: what was asked, what came back, and under what settings.
    ///
    /// All of it, because this is an experiment record rather than a
    /// transcript. Weeks later the question worth answering is usually "what
    /// was different about that run", and a transcript cannot say.
    public struct Turn: Codable, Sendable, Equatable {
        public struct Citation: Codable, Sendable, Equatable, Identifiable {
            /// Identity is the locator: one citation can name many chunks of a
            /// long document and the url is what tells them apart.
            public var id: String { "\(citation)|\(url)" }

            public var citation: String
            public var section: String
            public var url: String
            public var score: Float

            public init(citation: String, section: String, url: String, score: Float) {
                self.citation = citation
                self.section = section
                self.url = url
                self.score = score
            }
        }

        public var askedAt: Date
        public var question: String
        public var answer: String
        public var citations: [Citation]
        /// Retrieval settings in force, so two turns can be compared.
        public var k: Int
        public var hybrid: Bool
        public var embeddingModel: String
        /// Which machine answered and what it was doing, from the gateway's own
        /// `dai` block. A slow or odd answer is usually about the machine.
        public var answeredBy: String?
        public var presenceState: String?
        public var generationModel: String?
        public var seconds: Double?

        public init(askedAt: Date = Date(), question: String, answer: String,
                    citations: [Citation], k: Int, hybrid: Bool,
                    embeddingModel: String, answeredBy: String? = nil,
                    presenceState: String? = nil, generationModel: String? = nil,
                    seconds: Double? = nil) {
            self.askedAt = askedAt
            self.question = question
            self.answer = answer
            self.citations = citations
            self.k = k
            self.hybrid = hybrid
            self.embeddingModel = embeddingModel
            self.answeredBy = answeredBy
            self.presenceState = presenceState
            self.generationModel = generationModel
            self.seconds = seconds
        }
    }

    /// Append one turn. One line, flushed, so a crash loses at most this turn.
    public func append(_ turn: Turn) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(turn)
        line.append(0x0A)

        let fm = FileManager.default
        if !fm.fileExists(atPath: recordURL.path) {
            fm.createFile(atPath: recordURL.path, contents: line)
            return
        }
        let handle = try FileHandle(forWritingTo: recordURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Every turn, oldest first.
    ///
    /// A truncated final line is skipped rather than thrown on: a record that
    /// lost its last write is still the record of everything before it, and
    /// refusing to open the notebook would be a worse answer than losing one
    /// turn.
    public func turns() throws -> [Turn] {
        guard let data = FileManager.default.contents(atPath: recordURL.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(Turn.self, from: Data($0.utf8)) }
    }
}
