import Foundation
import SQLite3

/// The vector index inside a notebook, in the schema `rag_store.py` already uses.
///
/// **The schema is a contract, not an implementation detail.** A notebook's
/// `index.sqlite` is openable by `examples/python/rag_ask.py` with no new code,
/// which is worth more than it looks: there are now three retrieval
/// implementations in this repository that have to agree about prefixes,
/// pooling, normalisation and chunking, and a shared file is a stronger
/// guarantee than a shared protocol. Two programs reading the same bytes cannot
/// drift; two programs speaking the same API can, and did, and cost an
/// afternoon each time.
///
/// So every column here is the column Python writes, including the ones this
/// app has no use for. `division`, `chapter` and `article_name` are nullable and
/// unused by a notebook, and dropping them would produce a file the reference
/// implementation cannot read.
///
/// SQLite through the system library rather than a package. The schema is fixed
/// by the contract above, there is no migration story to own, and a dependency
/// that owns the schema would be a dependency that can change it.
public actor VectorStore {
    /// Owns the sqlite handle's lifetime.
    ///
    /// Swift 6 will not let a nonisolated `deinit` reach actor state, and the
    /// handle has to be closed exactly once by somebody. A final class whose
    /// only job is that closes it in its own deinit, off the actor, which is
    /// both what the language wants and a clearer statement of ownership than
    /// an optional the actor nils out.
    private final class Connection {
        let raw: OpaquePointer
        init(raw: OpaquePointer) { self.raw = raw }
        deinit { sqlite3_close_v2(raw) }
    }

    private let connection: Connection
    private var db: OpaquePointer { connection.raw }
    public let path: URL

    /// Little endian float32, which is what `numpy.float32.tobytes()` writes and
    /// what `numpy.frombuffer` expects. Stated because a vector written the
    /// other way round is still a blob of the right length: it reads back as
    /// numbers, scores as a cosine, ranks the corpus as noise, and nothing
    /// anywhere raises.
    public static let vectorElementSize = MemoryLayout<Float32>.size

    public enum StoreError: Error, CustomStringConvertible, Equatable {
        case cannotOpen(String)
        case sql(String)
        case dimensionMismatch(expected: Int, got: Int)
        case backendMismatch(stored: String, asked: String)

        public var description: String {
            switch self {
            case let .cannotOpen(p): return "could not open \(p)"
            case let .sql(m): return "sqlite: \(m)"
            case let .dimensionMismatch(expected, got):
                return "this notebook holds \(expected) dimension vectors and was "
                     + "given \(got). Two embedding models means two spaces, and "
                     + "mixing them returns plausible nonsense rather than an error."
            case let .backendMismatch(stored, asked):
                return "this notebook was embedded with \(stored) and the query "
                     + "used \(asked). A vector is only comparable to vectors "
                     + "from the model that produced it."
            }
        }
    }

    public init(path: URL, create: Bool = true) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = create
            ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            throw StoreError.cannotOpen(path.path)
        }
        self.connection = Connection(raw: handle)
        if create { try Self.applySchema(handle) }
    }

    // ------------------------------------------------------------- schema

    /// Byte for byte what `rag_store.py` creates. Changing anything here is a
    /// change to the contract and breaks `rag_ask.py` on every existing
    /// notebook.
    static let schema = """
    CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS chunks (
        id        INTEGER PRIMARY KEY,
        citation  TEXT NOT NULL,
        section   TEXT NOT NULL,
        division  TEXT,
        chapter   TEXT,
        chapter_name TEXT,
        url       TEXT NOT NULL,
        part      INTEGER NOT NULL DEFAULT 0,
        parts     INTEGER NOT NULL DEFAULT 1,
        text      TEXT NOT NULL,
        vector    BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS chunks_section ON chunks(section);
    """

    private static func applySchema(_ db: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, schema, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StoreError.sql(message)
        }
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StoreError.sql(message)
        }
    }

    // ------------------------------------------------------------- writing

    /// One chunk, in the shape both implementations read.
    public struct Chunk: Sendable, Equatable {
        public var citation: String
        public var section: String
        public var chapterName: String
        public var url: String
        public var part: Int
        public var parts: Int
        public var text: String

        public init(citation: String, section: String, chapterName: String = "",
                    url: String, part: Int = 0, parts: Int = 1, text: String) {
            self.citation = citation
            self.section = section
            self.chapterName = chapterName
            self.url = url
            self.part = part
            self.parts = parts
            self.text = text
        }
    }

    public func setMeta(_ key: String, _ value: some Encodable) throws {
        // Values are JSON, because that is how rag_store.py writes them and how
        // it will try to read them back. A bare string stored raw reads as
        // invalid JSON at the other end.
        let encoded = try JSONEncoder().encode(value)
        let json = String(decoding: encoded, as: UTF8.self)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db, "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)",
            -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        sqlite3_bind_text(statement, 2, json, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func meta(_ key: String) throws -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?",
                                 -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    /// Append chunks with their vectors, in one transaction.
    ///
    /// Dimensions are checked against what the notebook already holds rather
    /// than trusted. A shorter vector would be stored happily, read back as a
    /// different length, and score against every other chunk as though the
    /// missing dimensions were zero.
    public func add(_ chunks: [Chunk], vectors: [[Float]]) throws {
        guard !chunks.isEmpty else { return }
        precondition(chunks.count == vectors.count,
                     "add called with \(chunks.count) chunks and \(vectors.count) vectors")

        if let existing = try dimensionsOfFirstChunk() {
            for v in vectors where v.count != existing {
                throw StoreError.dimensionMismatch(expected: existing, got: v.count)
            }
        }
        if let first = vectors.first {
            for v in vectors where v.count != first.count {
                throw StoreError.dimensionMismatch(expected: first.count, got: v.count)
            }
        }

        try exec("BEGIN")
        do {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = """
            INSERT INTO chunks(citation, section, division, chapter, chapter_name,
                               url, part, parts, text, vector)
            VALUES (?, ?, NULL, NULL, ?, ?, ?, ?, ?, ?)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
            }
            for (chunk, vector) in zip(chunks, vectors) {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, chunk.citation, -1, Self.transient)
                sqlite3_bind_text(statement, 2, chunk.section, -1, Self.transient)
                sqlite3_bind_text(statement, 3, chunk.chapterName, -1, Self.transient)
                sqlite3_bind_text(statement, 4, chunk.url, -1, Self.transient)
                sqlite3_bind_int(statement, 5, Int32(chunk.part))
                sqlite3_bind_int(statement, 6, Int32(chunk.parts))
                sqlite3_bind_text(statement, 7, chunk.text, -1, Self.transient)
                let bytes = Self.blob(from: vector)
                bytes.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(statement, 8, raw.baseAddress,
                                          Int32(raw.count), Self.transient)
                }
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // ------------------------------------------------------------- reading

    public func count() throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM chunks",
                                 -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// How wide this notebook's vectors are, from the first one stored.
    ///
    /// Read rather than declared. An imported index knows its own width and the
    /// manifest should agree with it rather than with whatever the app would
    /// have chosen.
    public func dimensions() throws -> Int? { try dimensionsOfFirstChunk() }

    private func dimensionsOfFirstChunk() throws -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT vector FROM chunks LIMIT 1",
                                 -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_bytes(statement, 0)) / Self.vectorElementSize
    }

    /// The k nearest chunks, capped per section.
    ///
    /// The cap is carried from `rag_store.py` rather than reinvented: the
    /// longest section of a real corpus becomes twenty-odd chunks about one
    /// subject, and without a limit a single verbose section wins every slot
    /// and the answer is grounded in one place when it should be grounded in
    /// several. Retrieval quality is mostly this rule rather than the metric.
    public func search(_ query: [Float], k: Int = 6,
                       perSection: Int = 2) throws -> [(chunk: Chunk, score: Float)] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT citation, section, chapter_name, url, part, parts, text, vector
          FROM chunks ORDER BY id
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }

        var scored: [(Chunk, Float)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_blob(statement, 7) else { continue }
            let bytes = Int(sqlite3_column_bytes(statement, 7))
            let vector = Self.vector(from: Data(bytes: raw, count: bytes))
            guard vector.count == query.count else {
                throw StoreError.dimensionMismatch(expected: vector.count,
                                                   got: query.count)
            }
            var dot: Float = 0
            for i in 0 ..< vector.count { dot += vector[i] * query[i] }
            let chunk = Chunk(
                citation: Self.text(statement, 0), section: Self.text(statement, 1),
                chapterName: Self.text(statement, 2), url: Self.text(statement, 3),
                part: Int(sqlite3_column_int(statement, 4)),
                parts: Int(sqlite3_column_int(statement, 5)),
                text: Self.text(statement, 6))
            scored.append((chunk, dot))
        }

        var seen: [String: Int] = [:]
        var out: [(chunk: Chunk, score: Float)] = []
        for (chunk, score) in scored.sorted(by: { $0.1 > $1.1 }) {
            let n = seen[chunk.section, default: 0]
            if n >= perSection { continue }
            seen[chunk.section] = n + 1
            out.append((chunk, score))
            if out.count >= k { break }
        }
        return out
    }

    /// The stored text of one chunk, for showing what a citation named.
    ///
    /// Matched on the locator as well as the citation, because a long document
    /// produces many chunks under one citation and the url is what distinguishes
    /// them.
    public func text(forCitation citation: String, url: String) throws -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db, "SELECT text FROM chunks WHERE citation = ? AND url = ? LIMIT 1",
            -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(statement, 1, citation, -1, Self.transient)
        sqlite3_bind_text(statement, 2, url, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    // ------------------------------------------------------------- bytes

    public static func blob(from vector: [Float]) -> Data {
        var little = vector.map { $0.bitPattern.littleEndian }
        return Data(bytes: &little, count: little.count * vectorElementSize)
    }

    public static func vector(from data: Data) -> [Float] {
        let count = data.count / vectorElementSize
        var out = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            let start = i * vectorElementSize
            let bits = data[start ..< start + vectorElementSize]
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            out[i] = Float(bitPattern: UInt32(littleEndian: bits))
        }
        return out
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: raw)
    }

    /// SQLITE_TRANSIENT: sqlite copies the bytes rather than borrowing them.
    /// Binding Swift strings without this hands sqlite a pointer that is dead
    /// before the statement runs.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)
}
