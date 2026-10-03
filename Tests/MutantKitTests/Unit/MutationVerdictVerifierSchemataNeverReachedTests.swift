import Foundation
import MutationModel
import Testing

@Suite("Mutation verdict verifier: schemata runtime proves the mutated site was never reached")
struct MutationVerdictVerifierSchemataNeverReachedTests {
    private func observations(
        _ records: [RuntimeEventRecord], status: TestRunStatus = .passed
    ) throws -> MutationObservations {
        let point = try makeAnchoredPoint()
        let observation = SchemataExecutionObservation(
            expectation: makeSchemataExpectation(), buildReceipt: makeSchemataFixtureReceipt(),
            transcript: RuntimeTranscript(protocolVersion: 3, records: records)
        )
        let run = TestRunResult(
            status: status, summary: nil,
            command: CommandRecord(executable: "/usr/bin/true", arguments: [], workingDirectory: "/tmp"),
            resultArtifactPath: nil, diagnosis: "diag"
        )
        return MutationObservations(
            plannedMutation: PlannedMutationRef.forPoint(point, planID: "plan-A", workUnitID: "unit-1"),
            sourceApplication: .applied(makeEvidence(buildProductHash: "h1", applicationEvidence: .schemata(observation))),
            build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
            coverage: nil,
            test: SingleTestObservation(run: run, applicationEvidence: .schemata(observation))
        )
    }

    private func loaded(
        runID: RunID = schemataFixtureRunID, token: SchemataSelectorToken = schemataFixtureToken,
        imageUUID: ImageUUID = schemataFixtureImageUUID
    ) -> RuntimeEventRecord {
        .loaded(RuntimeLoadedEvent(runID: runID, token: token, processID: 4242, imageUUID: imageUUID, runtimeABIVersion: 1))
    }

    private var startup: RuntimeEventRecord {
        .startup(RuntimeStartupEvent(
            runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
            compilationUnitID: schemataFixtureCompilationUnitID, token: schemataFixtureToken,
            processID: 4242, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 1
        ))
    }

    private func outcome(_ records: [RuntimeEventRecord], status: TestRunStatus = .passed) throws -> MutationOutcome {
        try MutationVerdictVerifier.verify(observations(records, status: status), policy: .permissive).outcome
    }

    private func fallback(_ records: [RuntimeEventRecord]) throws -> MutationVerdictVerifier.SchemataIsolatedFallbackReason? {
        try MutationVerdictVerifier.schemataIsolatedFallbackReason(for: observations(records))
    }

    @Test("passed + runtime loaded + no STARTUP -> noCoverage, no isolated fallback")
    func loadedWithoutStartupIsNoCoverage() throws {
        #expect(try outcome([loaded()]) == .noCoverage)
        #expect(try fallback([loaded()]) == nil)
    }

    @Test("passed + runtime loaded + STARTUP without HIT -> noCoverage, no isolated fallback")
    func loadedWithoutHitIsNoCoverage() throws {
        #expect(try outcome([loaded(), startup]) == .noCoverage)
        #expect(try fallback([loaded(), startup]) == nil)
    }

    @Test("passed + no LOADED record -> isolated fallback, exactly as before")
    func missingLoadedStillFallsBack() throws {
        #expect(try fallback([]) == .noStartup)
        #expect(try fallback([startup]) == .noHit)
    }

    @Test(
        "passed + LOADED that does not match this run's identity -> isolated fallback",
        arguments: ["runID", "token", "image"]
    )
    func mismatchedLoadedStillFallsBack(field: String) throws {
        let record = switch field {
        case "runID": loaded(runID: RunID())
        case "token": loaded(token: SchemataSelectorToken(namespace: schemataFixtureToken.namespace, localIndex: schemataFixtureToken.localIndex + 1))
        default: loaded(imageUUID: try #require(ImageUUID(rawValue: String(repeating: "ab", count: 16))))
        }
        #expect(try fallback([record]) == .noStartup)
        #expect(try outcome([record]) == .infrastructureFailure)
    }

    @Test("failed + runtime loaded + no STARTUP never becomes noCoverage")
    func failedRunIsNeverNoCoverage() throws {
        #expect(try outcome([loaded()], status: .failed) != .noCoverage)
    }
}
