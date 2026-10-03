/// One `mutantkit_register_unit_v3` registration, decoded from a v3 STARTUP
/// record — fires unconditionally once a compilation unit's descriptor is
/// registered, whether or not its mutated call site is ever reached. See
/// `mutantkit_protocol_v3.h`'s own doc comment for why this exists
/// independent of `RuntimeHitEvent`.
public struct RuntimeStartupEvent: Codable, Sendable, Hashable {
    public let runID: RunID
    public let sourceEmbeddingID: SHA256Digest
    public let compilationUnitID: CompilationUnitID
    public let token: SchemataSelectorToken
    public let processID: Int32
    public let imageUUID: ImageUUID
    public let runtimeABIVersion: UInt32

    public init(
        runID: RunID, sourceEmbeddingID: SHA256Digest, compilationUnitID: CompilationUnitID, token: SchemataSelectorToken,
        processID: Int32, imageUUID: ImageUUID, runtimeABIVersion: UInt32
    ) {
        self.runID = runID
        self.sourceEmbeddingID = sourceEmbeddingID
        self.compilationUnitID = compilationUnitID
        self.token = token
        self.processID = processID
        self.imageUUID = imageUUID
        self.runtimeABIVersion = runtimeABIVersion
    }
}

/// One `mutantkit_is_active_v3` first-match, decoded from a v3 HIT record —
/// recorded at most once per process (the first activation in this process's
/// lifetime; see the C runtime's own doc comment on why a hit count is not
/// what scoring needs).
public struct RuntimeHitEvent: Codable, Sendable, Hashable {
    public let runID: RunID
    public let sourceEmbeddingID: SHA256Digest
    public let compilationUnitID: CompilationUnitID
    public let token: SchemataSelectorToken
    public let processID: Int32
    public let sequence: UInt64
    public let imageUUID: ImageUUID
    public let runtimeABIVersion: UInt32

    public init(
        runID: RunID, sourceEmbeddingID: SHA256Digest, compilationUnitID: CompilationUnitID, token: SchemataSelectorToken,
        processID: Int32, sequence: UInt64, imageUUID: ImageUUID, runtimeABIVersion: UInt32
    ) {
        self.runID = runID
        self.sourceEmbeddingID = sourceEmbeddingID
        self.compilationUnitID = compilationUnitID
        self.token = token
        self.processID = processID
        self.sequence = sequence
        self.imageUUID = imageUUID
        self.runtimeABIVersion = runtimeABIVersion
    }
}

/// The runtime's own image-load record, decoded from a v3 LOADED record —
/// proof the runtime was linked into, and loaded by, a test process that
/// was handed this run's token, whether or not any mutated site ever ran.
public struct RuntimeLoadedEvent: Codable, Sendable, Hashable {
    public let runID: RunID
    public let token: SchemataSelectorToken
    public let processID: Int32
    public let imageUUID: ImageUUID
    public let runtimeABIVersion: UInt32

    public init(runID: RunID, token: SchemataSelectorToken, processID: Int32, imageUUID: ImageUUID, runtimeABIVersion: UInt32) {
        self.runID = runID
        self.token = token
        self.processID = processID
        self.imageUUID = imageUUID
        self.runtimeABIVersion = runtimeABIVersion
    }
}

/// One decoded v3 event record — a STARTUP or a HIT, never filtered or
/// picked among by whatever parses raw transcript bytes into these (ADR-0006
/// Finding 3): ambiguity between two candidate events is a fact for a
/// caller doing chain selection to see and reject, not something a parser
/// resolves on the caller's behalf by returning only its own guess at "the"
/// relevant one.
public enum RuntimeEventRecord: Codable, Sendable, Hashable {
    case startup(RuntimeStartupEvent)
    case hit(RuntimeHitEvent)
    case loaded(RuntimeLoadedEvent)
}

/// Every event one schemata test process's runtime wrote, in the order the
/// process recorded them — the direct decode of a v3 binary transcript
/// file, before any interpretation. See `mutantkit_protocol_v3.h`.
public struct RuntimeTranscript: Codable, Sendable, Hashable {
    public let protocolVersion: UInt16
    public let records: [RuntimeEventRecord]

    public init(protocolVersion: UInt16, records: [RuntimeEventRecord]) {
        self.protocolVersion = protocolVersion
        self.records = records
    }
}
