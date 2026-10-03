@testable import AppleBuildAdapters
import Darwin
import Foundation
import MutationModel
import Testing

/// Proves the real, compiled `mutantkit_protocol_v3.c` runtime -- not a
/// reimplementation of its logic in Swift -- against a tiny C harness
/// built with the same `clang` `swift build` itself uses, linked against
/// the real `libMutantKitSchemataRuntime.a` `swift build --build-tests`
/// (already run before every test invocation) already produced.
///
/// This is the runtime half of ADR-0006 Stage 2's proof chain: the
/// generated preamble/collector (later stage-2 tasks) are not wired up
/// yet, so this test drives the C API directly rather than through a real
/// lowered mutation -- exactly the same reasoning
/// `MachOReceiptExtractorTests`'s hand-crafted-bytes tests use, plus one
/// real-binary cross-check (here: the harness's own `LC_UUID`, parsed
/// independently by `MachOReceiptExtractor`, must match what the C runtime
/// itself recorded for the same image).
@Suite("Schemata runtime protocol v3: real compiled runtime", .subprocessExclusive)
struct SchemataRuntimeProtocolV3Tests {
    private static let sourceEmbeddingHex = String(repeating: "ab", count: 32) // 64 hex chars
    private static let compilationUnitHex = String(repeating: "cd", count: 32) // 64 hex chars
    private static let runIDHex = String(repeating: "11", count: 16) // 32 hex chars

    private static let harnessSource = """
    #include "mutantkit_protocol_v3.h"
    #include <stdio.h>
    #include <stdlib.h>

    int main(int argc, char **argv) {
        if (argc != 5) {
            fprintf(stderr, "usage: harness <source_embedding_hex> <compilation_unit_hex> <namespace> <local_index>\\n");
            return 3;
        }
        const mutantkit_unit_descriptor_v3_t *descriptor = mutantkit_register_unit_v3(argv[1], argv[2]);
        if (descriptor == NULL) {
            printf("REGISTER_FAILED\\n");
            return 2;
        }
        unsigned long long namespace_value = strtoull(argv[3], NULL, 10);
        unsigned int local_index = (unsigned int)strtoul(argv[4], NULL, 10);
        bool active = mutantkit_is_active_v3(descriptor, (uint64_t)namespace_value, local_index);
        printf(active ? "ACTIVE\\n" : "INACTIVE\\n");
        return 0;
    }
    """

    /// Compiled once for the whole test run (a real `clang` invocation, not
    /// free) and reused by every test below, which only vary the
    /// environment/arguments they run it with. A `Result`, not a plain
    /// `URL` built with `try!`: a compile failure must surface as a normal
    /// thrown error from `harnessBinary()`, not a forced unwrap.
    private static let harnessBinaryResult: Result<URL, Error> = Result {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-v3-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("harness.c")
        try Data(harnessSource.utf8).write(to: sourceURL)
        let binaryURL = root.appendingPathComponent("harness")

        let includeDir = Acceptance.packageRoot.appendingPathComponent("Sources/MutantKitSchemataRuntimeC/include")
        let libDir = Acceptance.packageRoot.appendingPathComponent(".build/debug")

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = [
            "clang", "-I", includeDir.path, sourceURL.path,
            "-L", libDir.path, "-lMutantKitSchemataRuntime", "-o", binaryURL.path
        ]
        let pipe = Pipe()
        // Close-on-exec, immediately -- see AcceptanceSupport.cloexecPipe's
        // own doc comment for why: a real CI stack sample caught the
        // identical, unprotected-pipe pattern hung forever elsewhere in
        // this test suite (ProcessSupervisorResidueTests.swift).
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            let flags = fcntl(handle.fileDescriptor, F_GETFD)
            _ = fcntl(handle.fileDescriptor, F_SETFD, flags | FD_CLOEXEC)
        }
        compile.standardError = pipe
        compile.standardOutput = pipe
        try compile.run()
        let exitedOnItsOwn = BoundedProcessWait.wait(compile)
        guard exitedOnItsOwn, compile.terminationStatus == 0 else {
            let output = exitedOnItsOwn
                ? String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                : "compile timed out and was force-killed"
            throw HarnessCompileError.failed(output)
        }
        return binaryURL
    }

    private enum HarnessCompileError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(output): "failed to compile the v3 runtime harness: \(output)"
            }
        }
    }

    private static func harnessBinary() throws -> URL {
        try harnessBinaryResult.get()
    }

    private func run(
        environment: [String: String], arguments: [String] = [sourceEmbeddingHex, compilationUnitHex, "928374982374", "17"]
    ) throws -> (output: String, transcript: Data?) {
        let transcriptURL = environment["MUTANTKIT_SCHEMATA_TRANSCRIPT_PATH"].map { URL(fileURLWithPath: $0) }

        let process = Process()
        process.executableURL = try Self.harnessBinary()
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        // Close-on-exec, immediately -- see AcceptanceSupport.cloexecPipe's
        // own doc comment for why: a real CI stack sample caught the
        // identical, unprotected-pipe pattern hung forever elsewhere in
        // this test suite (ProcessSupervisorResidueTests.swift). This
        // function runs once per test, unlike the one-time cached compile
        // above, so it is the higher-frequency exposure of the two here.
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            let flags = fcntl(handle.fileDescriptor, F_GETFD)
            _ = fcntl(handle.fileDescriptor, F_SETFD, flags | FD_CLOEXEC)
        }
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        BoundedProcessWait.wait(process)

        let transcript = transcriptURL.flatMap { try? Data(contentsOf: $0) }
        return (String(decoding: data, as: UTF8.self), transcript)
    }

    private func makeTranscriptPath() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-v3-transcript-\(UUID().uuidString)")
    }

    // MARK: - Real record layout

    /// A parsed mirror of `mutantkit_event_record_v3_t` -- deliberately
    /// re-derived from the wire bytes here rather than imported from
    /// production code, since production has no v3 parser yet (task 7).
    private struct ParsedRecord: Equatable {
        let magic: UInt32
        let recordSize: UInt16
        let protocolVersion: UInt16
        let eventType: UInt8
        let runID: String
        let sourceEmbeddingID: String
        let compilationUnitID: String
        let namespaceValue: UInt64
        let localIndex: UInt32
        let processID: Int32
        let sequence: UInt64
        let imageUUID: String
        let runtimeABI: UInt32

        static let size = 136

        init?(_ data: Data) {
            guard data.count == Self.size else { return nil }
            var offset = 0
            func readU32BE() -> UInt32 {
                defer { offset += 4 }
                return data[data.startIndex + offset ..< data.startIndex + offset + 4].withUnsafeBytes {
                    UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
                }
            }
            func readU16BE() -> UInt16 {
                defer { offset += 2 }
                return data[data.startIndex + offset ..< data.startIndex + offset + 2].withUnsafeBytes {
                    UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self))
                }
            }
            func readU64BE() -> UInt64 {
                defer { offset += 8 }
                return data[data.startIndex + offset ..< data.startIndex + offset + 8].withUnsafeBytes {
                    UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self))
                }
            }
            func readBytes(_ count: Int) -> String {
                defer { offset += count }
                let slice = data[data.startIndex + offset ..< data.startIndex + offset + count]
                return slice.map { String(format: "%02x", $0) }.joined()
            }
            func skip(_ count: Int) { offset += count }

            magic = readU32BE()
            recordSize = readU16BE()
            protocolVersion = readU16BE()
            let type = data[data.startIndex + offset]
            offset += 1
            eventType = type
            skip(3) // reserved
            runID = readBytes(16)
            sourceEmbeddingID = readBytes(32)
            compilationUnitID = readBytes(32)
            namespaceValue = readU64BE()
            localIndex = readU32BE()
            processID = Int32(bitPattern: readU32BE())
            sequence = readU64BE()
            imageUUID = readBytes(16)
            runtimeABI = readU32BE()
        }
    }

    private func records(in transcript: Data?) -> [ParsedRecord] {
        guard let transcript, !transcript.isEmpty else { return [] }
        precondition(transcript.count.isMultiple(of: ParsedRecord.size))
        return stride(from: 0, to: transcript.count, by: ParsedRecord.size).compactMap {
            ParsedRecord(transcript.subdata(in: $0 ..< $0 + ParsedRecord.size))
        }
    }

    private static let loadedEventType: UInt8 = 3
    private static let zeroDigestHex = String(repeating: "0", count: 64)

    /// Every record except the image-level LOADED one, which the runtime
    /// writes from its constructor before any compilation unit registers.
    private func activationRecords(in transcript: Data?) -> [ParsedRecord] {
        records(in: transcript).filter { $0.eventType != Self.loadedEventType }
    }

    private func loadedRecords(in transcript: Data?) -> [ParsedRecord] {
        records(in: transcript).filter { $0.eventType == Self.loadedEventType }
    }

    // MARK: - Happy path

    @Test("a matching token records STARTUP then HIT, and reports ACTIVE")
    func matchingTokenRecordsStartupAndHit() throws {
        let transcriptURL = makeTranscriptPath()
        let result = try run(environment: [
            "MUTANTKIT_SCHEMATA_TOKEN": "928374982374:17",
            "MUTANTKIT_SCHEMATA_RUN_ID": Self.runIDHex,
            "MUTANTKIT_SCHEMATA_TRANSCRIPT_PATH": transcriptURL.path
        ])

        #expect(result.output == "ACTIVE\n")
        let all = records(in: result.transcript)
        let loaded = try #require(all.first)
        #expect(loaded.eventType == Self.loadedEventType) // written at image load, before anything else
        #expect(loaded.runID == Self.runIDHex)
        #expect(loaded.sourceEmbeddingID == Self.zeroDigestHex)
        #expect(loaded.compilationUnitID == Self.zeroDigestHex)
        #expect(loadedRecords(in: result.transcript).count == 1)

        let parsed = activationRecords(in: result.transcript)
        #expect(parsed.count == 2)
        #expect(parsed[0].eventType == 1) // STARTUP
        #expect(parsed[1].eventType == 2) // HIT

        for record in parsed {
            #expect(record.magic == 0x4D4B_5633)
            #expect(record.recordSize == 136)
            #expect(record.protocolVersion == 3)
            #expect(record.runID == Self.runIDHex)
            #expect(record.sourceEmbeddingID == Self.sourceEmbeddingHex)
            #expect(record.compilationUnitID == Self.compilationUnitHex)
            #expect(record.processID > 0)
            #expect(record.runtimeABI == 1)
        }
        #expect(parsed[1].namespaceValue == 928_374_982_374)
        #expect(parsed[1].localIndex == 17)
        #expect(loaded.sequence < parsed[0].sequence)
        #expect(parsed[0].sequence < parsed[1].sequence)

        // Cross-check: the image UUID the C runtime recorded for the
        // harness process must match what an independent Swift-side
        // Mach-O parser reads from the same harness binary on disk --
        // proof this isn't two implementations quietly agreeing by
        // coincidence.
        let inspected = try MachOReceiptExtractor().inspectImage(at: Self.harnessBinary())
        let extractedUUIDs = Set(inspected.slices.map(\.imageUUID.rawValue))
        #expect(extractedUUIDs.contains(parsed[0].imageUUID))
        #expect(loaded.imageUUID == parsed[0].imageUUID)
    }

    // MARK: - Non-matching token

    @Test("a non-matching token records STARTUP but never HIT, and reports INACTIVE")
    func nonMatchingTokenNeverRecordsHit() throws {
        let transcriptURL = makeTranscriptPath()
        let result = try run(
            environment: [
                "MUTANTKIT_SCHEMATA_TOKEN": "1:1", // does not match the harness's requested 928374982374:17
                "MUTANTKIT_SCHEMATA_RUN_ID": Self.runIDHex,
                "MUTANTKIT_SCHEMATA_TRANSCRIPT_PATH": transcriptURL.path
            ]
        )

        #expect(result.output == "INACTIVE\n")
        #expect(loadedRecords(in: result.transcript).count == 1)
        let parsed = activationRecords(in: result.transcript)
        #expect(parsed.count == 1)
        #expect(parsed[0].eventType == 1) // STARTUP only
    }

    @Test("no token at all records nothing at all, and reports INACTIVE")
    func noTokenRecordsNothing() throws {
        // Matches v2's own STARTUP semantics: a process that requested no
        // token at all never writes STARTUP either -- there is no
        // meaningful (namespace, localIndex) to attribute it to, and
        // writing one with a literal (0, 0) would encode the reserved
        // "inactive" sentinel into a record a host parses expecting a real
        // token.
        let transcriptURL = makeTranscriptPath()
        let result = try run(environment: [
            "MUTANTKIT_SCHEMATA_RUN_ID": Self.runIDHex,
            "MUTANTKIT_SCHEMATA_TRANSCRIPT_PATH": transcriptURL.path
        ])

        #expect(result.output == "INACTIVE\n")
        #expect(records(in: result.transcript).isEmpty)
    }

    // MARK: - Registration failure

    @Test("malformed source embedding hex fails registration; only the image LOADED record is written")
    func malformedSourceEmbeddingHexFailsRegistration() throws {
        let transcriptURL = makeTranscriptPath()
        let result = try run(
            environment: [
                "MUTANTKIT_SCHEMATA_TOKEN": "928374982374:17",
                "MUTANTKIT_SCHEMATA_RUN_ID": Self.runIDHex,
                "MUTANTKIT_SCHEMATA_TRANSCRIPT_PATH": transcriptURL.path
            ],
            arguments: ["not-hex-at-all", Self.compilationUnitHex, "928374982374", "17"]
        )

        #expect(result.output == "REGISTER_FAILED\n")
        #expect(activationRecords(in: result.transcript).isEmpty)
        #expect(loadedRecords(in: result.transcript).count == 1)
    }

    // MARK: - Missing run ID

    @Test("a missing run ID still activates but records nothing at all -- fail closed on evidence, not on behavior")
    func missingRunIDActivatesButRecordsNothing() throws {
        let transcriptURL = makeTranscriptPath()
        let result = try run(environment: [
            "MUTANTKIT_SCHEMATA_TOKEN": "928374982374:17",
            "MUTANTKIT_SCHEMATA_TRANSCRIPT_PATH": transcriptURL.path
            // MUTANTKIT_SCHEMATA_RUN_ID deliberately omitted.
        ])

        #expect(result.output == "ACTIVE\n")
        #expect(result.transcript == nil || result.transcript?.isEmpty == true)
    }

    // MARK: - Transcript file permissions

    /// Sonar flagged the runtime's `open()` call for creating this file
    /// world/group-readable (0644); fixed to owner-only (0600). A future
    /// reimplementation of `mutantkit_v3_write_record` must not regress
    /// back to 0644 without this test failing.
    @Test("the transcript file the runtime creates is owner-only (0600), not group/other-readable")
    func transcriptFileIsCreatedOwnerOnly() throws {
        let transcriptURL = makeTranscriptPath()
        _ = try run(environment: [
            "MUTANTKIT_SCHEMATA_TOKEN": "928374982374:17",
            "MUTANTKIT_SCHEMATA_RUN_ID": Self.runIDHex,
            "MUTANTKIT_SCHEMATA_TRANSCRIPT_PATH": transcriptURL.path
        ])

        let attributes = try FileManager.default.attributesOfItem(atPath: transcriptURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)
    }

    // MARK: - Sequence numbers span multiple invocations correctly

    @Test("each process's own sequence starts fresh at 1, not continuing a shared file's prior count")
    func sequenceStartsFreshPerProcess() throws {
        let transcriptURL = makeTranscriptPath()
        let environment = [
            "MUTANTKIT_SCHEMATA_TOKEN": "928374982374:17",
            "MUTANTKIT_SCHEMATA_RUN_ID": Self.runIDHex,
            "MUTANTKIT_SCHEMATA_TRANSCRIPT_PATH": transcriptURL.path
        ]
        _ = try run(environment: environment)
        let second = try run(environment: environment)

        let parsed = records(in: second.transcript)
        // The second process appended its own LOADED+STARTUP+HIT after the
        // first's three records already in the (shared) file -- 6 total,
        // and the second process's own records start their sequence at 1
        // again (a per-process counter, not a shared one).
        #expect(parsed.count == 6)
        #expect(parsed[3].sequence == 1)
        #expect(parsed[4].sequence == 2)
        #expect(parsed[5].sequence == 3)
        #expect(parsed[3].processID != parsed[0].processID)
    }
}
