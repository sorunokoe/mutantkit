import Foundation
import MutationModel

/// Parses the binary transcript `MutantKitSchemataRuntimeC`'s v3 runtime
/// (`mutantkit_protocol_v3.c`) writes into a raw `RuntimeTranscript` — the
/// host-side half of the runtime protocol: the C library runs inside the
/// mutated target-under-test's own process and knows nothing about Swift
/// types; this reads what it left behind after that process exits. Decodes
/// only; deciding which (if any) event is real evidence is
/// `MutationVerdictVerifier.verifySchemataChain`'s job alone (ADR-0006
/// Stage 2) — this type never matches or picks among candidates.
///
/// Deliberately not linked against the C target (see `Package.swift`'s
/// `MutationExecution` target comment) — the environment variable names and
/// `mutantkit_protocol_v3.h`'s binary record layout are the entire contract
/// between the two sides. `parseTranscript` mirrors that header's exact
/// field offsets; a layout change on one side without the other is caught by
/// `record_size`/`protocol_version` mismatching, not a silently misread
/// field.
public enum SchemataEvidenceCollector {
    /// Set before launching the mutated process: which token to activate,
    /// `"<namespace>:<localIndex>"` decimal. Unset or malformed means
    /// nothing activates — see `mutantkit_protocol_v3.h`'s own doc comment.
    public static let tokenEnvironmentVariable = "MUTANTKIT_SCHEMATA_TOKEN"
    /// Set before launching the mutated process: where the runtime appends
    /// one binary record per STARTUP/HIT event — a single combined
    /// transcript, unlike v2's separate startup/evidence files, since a v3
    /// record already carries an `event_type` field distinguishing the two.
    /// Unset means every event this process would have recorded is lost —
    /// never a fabricated absence-of-evidence-means-success reading, the
    /// same `unprovenActivation` discipline `MutationVerdictVerifier`
    /// applies elsewhere.
    public static let transcriptPathEnvironmentVariable = "MUTANTKIT_SCHEMATA_TRANSCRIPT_PATH"
    /// Set before launching the mutated process: this run's `RunID`, hex-
    /// encoded (32 lowercase hex characters, `ImageUUID`-shaped — see
    /// `mutantkit_protocol_v3.h`'s `MUTANTKIT_V3_RUN_ID_SIZE`). Without
    /// this, an event's `processID`/token match alone cannot distinguish a
    /// genuine event for *this* run from a stale one left over from an
    /// earlier run that happened to reuse the same PID and request the same
    /// token.
    public static let runIDEnvironmentVariable = "MUTANTKIT_SCHEMATA_RUN_ID"

    /// A `RunID`'s wire form for `runIDEnvironmentVariable` — 32 lowercase
    /// hex characters, matching what `mutantkit_v3_decode_hex` on the C
    /// side expects, not `UUID.uuidString`'s hyphenated/uppercase display
    /// form.
    public static func runIDEnvironmentValue(for runID: RunID) -> String {
        runID.rawValue.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public static func tokenEnvironmentValue(for token: SchemataSelectorToken) -> String {
        "\(token.namespace):\(token.localIndex)"
    }

    /// Every way a chunk of transcript bytes fails to decode as v3 records —
    /// each is a refusal, never a best-effort partial read. A transcript
    /// this codebase's own runtime wrote is always a whole multiple of one
    /// fixed record size; anything else means truncation, corruption, or a
    /// version mismatch between the linked runtime and this host.
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case truncatedTranscript(byteCount: Int)
        case unrecognizedMagic(UInt32)
        case unsupportedRecordSize(UInt16)
        case unsupportedProtocolVersion(UInt16)
        case unrecognizedEventType(UInt8)
        case invalidLocalIndex

        public var description: String {
            switch self {
            case let .truncatedTranscript(byteCount):
                "transcript is \(byteCount) bytes, not a whole multiple of the \(SchemataEvidenceCollector.recordSize)-byte v3 record size"
            case let .unrecognizedMagic(magic):
                "record magic 0x\(String(magic, radix: 16)) does not match the expected v3 magic"
            case let .unsupportedRecordSize(size):
                "record declares its own size as \(size), this host only understands \(SchemataEvidenceCollector.recordSize)"
            case let .unsupportedProtocolVersion(version):
                "record declares protocol version \(version), this host only understands \(SchemataEvidenceCollector.protocolVersion)"
            case let .unrecognizedEventType(type):
                "record declares event type \(type), not STARTUP (1), HIT (2), or LOADED (3)"
            case .invalidLocalIndex:
                "record's localIndex is 0, the reserved inactive sentinel — never a valid token in a genuine event"
            }
        }
    }

    /// Mirrors `MUTANTKIT_V3_MAGIC`/`MUTANTKIT_V3_PROTOCOL_VERSION` and
    /// `mutantkit_event_record_v3_t`'s `sizeof` from `mutantkit_protocol_v3.h`
    /// exactly.
    static let magic: UInt32 = 0x4D4B_5633
    static let protocolVersion: UInt16 = 3
    static let recordSize = 136

    /// Parses every fixed-size record in `data`, in file order — no
    /// filtering, no picking a "first" or "last" among candidates (ADR-0006
    /// Finding 3): that is a chain-selection decision for a caller building
    /// evidence to make deliberately, with every candidate in view, not
    /// something this parser resolves by discarding the others first.
    public static func parseTranscript(from data: Data) throws -> RuntimeTranscript {
        guard !data.isEmpty else { return RuntimeTranscript(protocolVersion: protocolVersion, records: []) }
        guard data.count.isMultiple(of: recordSize) else {
            throw ParseError.truncatedTranscript(byteCount: data.count)
        }

        var records: [RuntimeEventRecord] = []
        for offset in stride(from: 0, to: data.count, by: recordSize) {
            records.append(try parseRecord(data.subdata(in: offset ..< offset + recordSize)))
        }
        return RuntimeTranscript(protocolVersion: protocolVersion, records: records)
    }

    private static func parseRecord(_ record: Data) throws -> RuntimeEventRecord {
        guard let magicValue = record.readUInt32BE(at: 0), magicValue == magic else {
            throw ParseError.unrecognizedMagic(record.readUInt32BE(at: 0) ?? 0)
        }
        guard let recordSizeValue = record.readUInt16BE(at: 4), Int(recordSizeValue) == recordSize else {
            throw ParseError.unsupportedRecordSize(record.readUInt16BE(at: 4) ?? 0)
        }
        guard let protocolVersionValue = record.readUInt16BE(at: 6), protocolVersionValue == protocolVersion else {
            throw ParseError.unsupportedProtocolVersion(record.readUInt16BE(at: 6) ?? 0)
        }
        let eventType = record[record.startIndex + 8]

        let runID = RunID(bytes: record.readBytes(at: 12, count: 16))
        let sourceEmbeddingID = SHA256Digest(hexBytes: record.readBytes(at: 28, count: 32))
        let compilationUnitID = CompilationUnitID(hexBytes: record.readBytes(at: 60, count: 32))
        guard let namespaceValue = record.readUInt64BE(at: 92), let localIndexValue = record.readUInt32BE(at: 100) else {
            throw ParseError.invalidLocalIndex
        }
        guard localIndexValue > 0 else { throw ParseError.invalidLocalIndex }
        let token = SchemataSelectorToken(namespace: namespaceValue, localIndex: localIndexValue)
        guard let processIDValue = record.readUInt32BE(at: 104), let sequenceValue = record.readUInt64BE(at: 108),
              let runtimeABIValue = record.readUInt32BE(at: 132)
        else {
            throw ParseError.invalidLocalIndex
        }
        let processID = Int32(bitPattern: processIDValue)
        let imageUUID = ImageUUID(hexBytes: record.readBytes(at: 116, count: 16))

        switch eventType {
        case 1:
            return .startup(RuntimeStartupEvent(
                runID: runID, sourceEmbeddingID: sourceEmbeddingID, compilationUnitID: compilationUnitID, token: token,
                processID: processID, imageUUID: imageUUID, runtimeABIVersion: runtimeABIValue
            ))
        case 2:
            return .hit(RuntimeHitEvent(
                runID: runID, sourceEmbeddingID: sourceEmbeddingID, compilationUnitID: compilationUnitID, token: token,
                processID: processID, sequence: sequenceValue, imageUUID: imageUUID, runtimeABIVersion: runtimeABIValue
            ))
        case 3:
            return .loaded(RuntimeLoadedEvent(
                runID: runID, token: token, processID: processID, imageUUID: imageUUID, runtimeABIVersion: runtimeABIValue
            ))
        default:
            throw ParseError.unrecognizedEventType(eventType)
        }
    }

    /// Reads and parses whatever transcript exists at `transcriptPath` —
    /// the raw-observation counterpart to the old `collectActivationEvidence`
    /// (ADR-0006 Stage 2): this reads and decodes bytes, nothing more. No
    /// STARTUP/HIT matching happens here at all; deciding which candidate
    /// (if any) is real is `MutationVerdictVerifier.verifySchemataChain`'s
    /// job alone, once this raw `RuntimeTranscript` reaches it inside a
    /// `SchemataExecutionObservation`. A missing file (the runtime never
    /// linked, or never parsed a token) is reported as an empty transcript
    /// — never a fabricated absence-of-evidence-means-success reading.
    public static func readTranscript(at transcriptPath: URL) throws -> RuntimeTranscript {
        guard let data = try? Data(contentsOf: transcriptPath) else {
            return RuntimeTranscript(protocolVersion: protocolVersion, records: [])
        }
        return try parseTranscript(from: data)
    }
}

// MARK: - Bounds-checked big-endian reads

private extension Data {
    func hasBytes(at offset: Int, count: Int) -> Bool {
        offset >= 0 && offset + count <= self.count
    }

    func readUInt16BE(at offset: Int) -> UInt16? {
        guard hasBytes(at: offset, count: 2) else { return nil }
        let bytes = subdata(in: startIndex + offset ..< startIndex + offset + 2)
        return bytes.withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self)) }
    }

    func readUInt32BE(at offset: Int) -> UInt32? {
        guard hasBytes(at: offset, count: 4) else { return nil }
        let bytes = subdata(in: startIndex + offset ..< startIndex + offset + 4)
        return bytes.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    func readUInt64BE(at offset: Int) -> UInt64? {
        guard hasBytes(at: offset, count: 8) else { return nil }
        let bytes = subdata(in: startIndex + offset ..< startIndex + offset + 8)
        return bytes.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self)) }
    }

    /// Returns exactly `count` bytes, or an empty array if out of bounds —
    /// only ever called after the fixed-record-size check in
    /// `parseTranscript` already guarantees every field offset is in
    /// bounds, so an empty result here is unreachable in practice, not a
    /// silently-tolerated short read.
    func readBytes(at offset: Int, count: Int) -> [UInt8] {
        guard hasBytes(at: offset, count: count) else { return [] }
        return Array(subdata(in: startIndex + offset ..< startIndex + offset + count))
    }
}

extension RunID {
    /// Constructs from 16 raw bytes (a v3 record's `run_id` field) — any 16
    /// bytes are a valid `UUID` bit pattern, so this never fails the way
    /// parsing a hex *string* could.
    init(bytes: [UInt8]) {
        precondition(bytes.count == 16, "a RunID's raw form is always exactly 16 bytes")
        self.init(rawValue: NSUUID(uuidBytes: bytes) as UUID)
    }
}

private extension SHA256Digest {
    init(hexBytes bytes: [UInt8]) {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        guard let value = SHA256Digest(rawValue: hex) else {
            preconditionFailure("32 raw bytes rendered as 64 lowercase hex characters must always validate")
        }
        self = value
    }
}

private extension CompilationUnitID {
    init(hexBytes bytes: [UInt8]) {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        guard let value = CompilationUnitID(rawValue: hex) else {
            preconditionFailure("32 raw bytes rendered as 64 lowercase hex characters must always validate")
        }
        self = value
    }
}

private extension ImageUUID {
    init(hexBytes bytes: [UInt8]) {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        guard let value = ImageUUID(rawValue: hex) else {
            preconditionFailure("16 raw bytes rendered as 32 lowercase hex characters must always validate")
        }
        self = value
    }
}
