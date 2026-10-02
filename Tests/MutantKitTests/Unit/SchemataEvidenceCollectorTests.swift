import Foundation
import MutationExecution
import MutationModel
import Testing

/// Pins `SchemataEvidenceCollector`'s parsing of the v3 binary transcript
/// format `mutantkit_protocol_v3.c` writes (STARTUP/HIT records) and
/// `readTranscript`'s own file-I/O boundary. Deliberately does NOT pin any
/// STARTUP/HIT matching behavior — that decision belongs solely to
/// `MutationVerdictVerifier.verifySchemataChain` (ADR-0006 Stage 2), pinned
/// by `MutationVerdictVerifierTests`'s own schemata-chain test group.
/// `SchemataSwiftPMRuntimeAcceptanceTests` separately proves this parser
/// against the *real* C runtime's actual output, not just these
/// hand-crafted fixture records.
@Suite("SchemataEvidenceCollector")
struct SchemataEvidenceCollectorTests {
    private static let token = SchemataSelectorToken(namespace: 42, localIndex: 3)
    private static let runID = RunID()

    // MARK: - Hand-crafted record construction

    private static func hex32Bytes(_ seed: UInt8) -> [UInt8] { Array(repeating: seed, count: 32) }
    private static func hex16Bytes(_ seed: UInt8) -> [UInt8] { Array(repeating: seed, count: 16) }

    private func record(
        eventType: UInt8,
        runID: RunID = Self.runID,
        sourceEmbeddingID: [UInt8] = Self.hex32Bytes(0xAA),
        compilationUnitID: [UInt8] = Self.hex32Bytes(0xBB),
        namespace: UInt64 = 42,
        localIndex: UInt32 = 3,
        processID: Int32 = 4242,
        sequence: UInt64 = 1,
        imageUUID: [UInt8] = Self.hex16Bytes(0xCC),
        runtimeABI: UInt32 = 1
    ) -> Data {
        var data = Data()
        data.appendBE(UInt32(0x4D4B_5633)) // magic
        data.appendBE(UInt16(136)) // record_size
        data.appendBE(UInt16(3)) // protocol_version
        data.append(eventType)
        data.append(contentsOf: [0, 0, 0]) // reserved
        data.append(contentsOf: runID.rawValue.rawBytes)
        data.append(contentsOf: sourceEmbeddingID)
        data.append(contentsOf: compilationUnitID)
        data.appendBE(namespace)
        data.appendBE(localIndex)
        data.appendBE(UInt32(bitPattern: processID))
        data.appendBE(sequence)
        data.append(contentsOf: imageUUID)
        data.appendBE(runtimeABI)
        precondition(data.count == 136)
        return data
    }

    private func startupRecord(
        runID: RunID = Self.runID, namespace: UInt64 = 42, localIndex: UInt32 = 3, processID: Int32 = 4242,
        imageUUID: [UInt8] = Self.hex16Bytes(0xCC), compilationUnitID: [UInt8] = Self.hex32Bytes(0xBB)
    ) -> Data {
        record(
            eventType: 1, runID: runID, compilationUnitID: compilationUnitID, namespace: namespace, localIndex: localIndex,
            processID: processID, sequence: 0, imageUUID: imageUUID
        )
    }

    private func hitRecord(
        runID: RunID = Self.runID, namespace: UInt64 = 42, localIndex: UInt32 = 3, processID: Int32 = 4242,
        sequence: UInt64 = 1, imageUUID: [UInt8] = Self.hex16Bytes(0xCC), compilationUnitID: [UInt8] = Self.hex32Bytes(0xBB)
    ) -> Data {
        record(
            eventType: 2, runID: runID, compilationUnitID: compilationUnitID, namespace: namespace, localIndex: localIndex,
            processID: processID, sequence: sequence, imageUUID: imageUUID
        )
    }

    // MARK: - parseTranscript

    @Test("A well-formed STARTUP record parses correctly")
    func parsesWellFormedStartupRecord() throws {
        let transcript = try SchemataEvidenceCollector.parseTranscript(from: startupRecord())
        #expect(transcript.records.count == 1)
        guard case let .startup(event) = transcript.records[0] else {
            Issue.record("expected a startup event")
            return
        }
        #expect(event.token == Self.token)
        #expect(event.processID == 4242)
        #expect(event.runID == Self.runID)
    }

    @Test("A well-formed LOADED record parses correctly")
    func parsesWellFormedLoadedRecord() throws {
        let data = record(eventType: 3, sourceEmbeddingID: Self.hex32Bytes(0), compilationUnitID: Self.hex32Bytes(0), sequence: 0)
        let transcript = try SchemataEvidenceCollector.parseTranscript(from: data)
        guard case let .loaded(event) = try #require(transcript.records.first) else {
            Issue.record("expected a loaded event")
            return
        }
        #expect(event.token == Self.token)
        #expect(event.runID == Self.runID)
        #expect(event.processID == 4242)
        #expect(event.imageUUID.rawValue == String(repeating: "cc", count: 16))
    }

    @Test("An unknown event type is refused")
    func refusesUnknownEventType() {
        #expect(throws: SchemataEvidenceCollector.ParseError.unrecognizedEventType(4)) {
            try SchemataEvidenceCollector.parseTranscript(from: record(eventType: 4))
        }
    }

    @Test("A well-formed HIT record parses correctly")
    func parsesWellFormedHitRecord() throws {
        let transcript = try SchemataEvidenceCollector.parseTranscript(from: hitRecord(sequence: 7))
        guard case let .hit(event) = try #require(transcript.records.first) else {
            Issue.record("expected a hit event")
            return
        }
        #expect(event.sequence == 7)
        #expect(event.token == Self.token)
    }

    @Test("Multiple records all parse, in file order")
    func parsesMultipleRecords() throws {
        var data = startupRecord()
        data.append(hitRecord(sequence: 1))
        data.append(hitRecord(sequence: 2))
        let transcript = try SchemataEvidenceCollector.parseTranscript(from: data)
        #expect(transcript.records.count == 3)
    }

    @Test("Empty data parses to no records")
    func parsesEmptyData() throws {
        #expect(try SchemataEvidenceCollector.parseTranscript(from: Data()).records.isEmpty)
    }

    @Test("A localIndex of 0 (the reserved sentinel) makes parsing fail rather than silently accepted")
    func rejectsReservedSentinelLocalIndex() {
        #expect(throws: SchemataEvidenceCollector.ParseError.self) {
            _ = try SchemataEvidenceCollector.parseTranscript(from: startupRecord(localIndex: 0))
        }
    }

    @Test("Data whose length is not a whole multiple of the record size throws, not silently truncated")
    func rejectsTruncatedTranscript() {
        var data = startupRecord()
        data.removeLast()
        #expect(throws: SchemataEvidenceCollector.ParseError.self) {
            _ = try SchemataEvidenceCollector.parseTranscript(from: data)
        }
    }

    @Test("An unrecognized magic number is rejected")
    func rejectsUnrecognizedMagic() {
        var data = startupRecord()
        data.replaceSubrange(0 ..< 4, with: [0, 0, 0, 0])
        #expect(throws: SchemataEvidenceCollector.ParseError.self) {
            _ = try SchemataEvidenceCollector.parseTranscript(from: data)
        }
    }

    @Test("A record declaring an unsupported protocol version is rejected, not misparsed")
    func rejectsUnsupportedProtocolVersion() {
        var data = startupRecord()
        data.replaceSubrange(6 ..< 8, with: [0, 2]) // protocol_version = 2
        #expect(throws: SchemataEvidenceCollector.ParseError.self) {
            _ = try SchemataEvidenceCollector.parseTranscript(from: data)
        }
    }

    @Test("An unrecognized event type is rejected")
    func rejectsUnrecognizedEventType() {
        var data = startupRecord()
        data[data.startIndex + 8] = 9
        #expect(throws: SchemataEvidenceCollector.ParseError.self) {
            _ = try SchemataEvidenceCollector.parseTranscript(from: data)
        }
    }

    // MARK: - readTranscript

    private func withTranscriptFile<T>(_ contents: Data?, _ body: (URL) throws -> T) rethrows -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("schemata-\(UUID().uuidString).bin")
        if let contents {
            try? contents.write(to: url)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }

    @Test("readTranscript decodes every record a real file on disk contains, in file order")
    func readTranscriptDecodesRealFile() throws {
        var transcript = startupRecord()
        transcript.append(hitRecord(sequence: 7))
        try withTranscriptFile(transcript) { transcriptPath in
            let decoded = try SchemataEvidenceCollector.readTranscript(at: transcriptPath)
            #expect(decoded.records.count == 2)
            guard case .startup = decoded.records[0], case let .hit(hit) = decoded.records[1] else {
                Issue.record("expected [startup, hit] in file order")
                return
            }
            #expect(hit.sequence == 7)
        }
    }

    @Test("readTranscript reports a missing file as an empty transcript, never a fabricated one")
    func readTranscriptReportsMissingFileAsEmpty() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).bin")
        let decoded = try SchemataEvidenceCollector.readTranscript(at: missing)
        #expect(decoded.records.isEmpty)
    }

    @Test("readTranscript throws for a present but malformed file, rather than silently reporting it empty")
    func readTranscriptThrowsForMalformedFile() throws {
        var transcript = startupRecord()
        transcript.removeLast()
        _ = withTranscriptFile(transcript) { transcriptPath in
            #expect(throws: SchemataEvidenceCollector.ParseError.self) {
                _ = try SchemataEvidenceCollector.readTranscript(at: transcriptPath)
            }
        }
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt16) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: UInt64) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}

private extension UUID {
    var rawBytes: [UInt8] {
        let u = uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }
}
