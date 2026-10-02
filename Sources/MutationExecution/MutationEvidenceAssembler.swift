import Foundation
import MutationModel
import SwiftFrontend

/// Turns raw build/test/application observations into the evidence
/// structures a `MutationResult` carries, and — through `finalize` — is the
/// single path from those observations to a reportable result.
///
/// Extracted out of `MutationRunner` (Phase A1 of the execution-pipeline
/// decomposition): every stored property here is one of `MutationRunner`'s
/// own dependencies for exactly this job — `plan` for the `planID`/
/// `workUnitID` a result is stamped with, `configuration` for the
/// confirmation policy `MutationVerdictVerifier` is judged against,
/// `checkpoints`/`resultCache`/`progress`/`operationalIssues` for
/// `finalize`'s own persistence side effects. `operationalIssues` in
/// particular is the *same* `OperationalIssueLog` instance
/// `MutationRunner` itself holds and reads at the end of `run()` — passed
/// in at construction, not created here — so a warning `finalize` records
/// still reaches that run's own `RunReport.operationalIssues`.
struct MutationEvidenceAssembler: Sendable {
    let plan: MutationPlan
    let configuration: Configuration
    let checkpoints: CheckpointStore?
    let artifactsRoot: URL?
    let resultCache: MutationResultCache?
    let resultCacheDigest: String?
    let progress: MutationProgressReporter?
    let operationalIssues: OperationalIssueLog

    /// The confirmation policy this run is actually gated on — passed to
    /// `MutationVerdictVerifier.verify` so it can require the confirmation
    /// `finishAfterTest`'s own `configuration.execution.retestKilledMutants`/
    /// `confirmCrashKills` checks promise, rather than trusting whatever
    /// `confirmations` a reverified `MutationObservations` happens to carry.
    private var verificationPolicy: MutationVerdictVerifier.VerdictVerificationPolicy {
        MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: configuration.execution.retestKilledMutants,
            confirmCrashKills: configuration.execution.confirmCrashKills,
            confirmTimedOutMutants: configuration.execution.confirmTimedOutMutants
        )
    }

    /// Whether the mutation reached the binary the tests ran against.
    ///
    /// In isolated mode the edit is compiled in, so a mutant product identical
    /// to the baseline's is proof the mutation did *not* run — whatever the
    /// source diff says. `nil` means the adapter could not tell us, which is not
    /// the same as either answer.
    static func activationEvidence(mutantHash: String?, baselineHash: String?) -> ActivationEvidence? {
        guard let mutantHash, let baselineHash else { return nil }
        return mutantHash == baselineHash
            ? .buildProductIdenticalToBaseline(hash: mutantHash)
            : .buildProductDiffersFromBaseline(mutantHash: mutantHash, baselineHash: baselineHash)
    }

    /// ADR-0006 Stage 1: the single path from raw observations to a
    /// reportable result — `MutationObservations -> MutationVerdictVerifier
    /// -> MutationResult` projection. There is no other way for this file
    /// to produce a `MutationResult`: `prepare`'s `finished` closure,
    /// `finishAfterTest`, and every pre-classification infrastructure-
    /// failure early exit (sandbox creation, a build/test launch failure)
    /// all route through here — including the early exits, which PR B
    /// (ADR-0005) deliberately left outside the verifier because there was
    /// "no classification decision to sit in front of." That reasoning
    /// under-weighted the actual goal: the point was never "re-check a
    /// classifier's judgment," it is "nothing constructs a `MutationResult`
    /// outside this one path." An infrastructure failure has an outcome
    /// (`.infrastructureFailure`) and a diagnosis; that is enough for
    /// `MutationObservations.infrastructureFailureDiagnosis` today.
    ///
    /// `workUnitID` is `plan.workUnitID` (a real shard identity, not
    /// `plan.planID`, which stays constant across every shard of the same
    /// plan and so cannot distinguish them) — `plan.planID` was used here
    /// before Stage 1; that was a real bug this stage fixes, not a
    /// simplification.
    /// The single choke point from raw observations to a persisted,
    /// reportable result — every result-producing path in this file ends
    /// here, directly or through `finishAfterTest`/`infrastructureFailureResult`.
    ///
    /// ADR-0006 Stage 1 (second review round): persistence now happens
    /// *here*, not at each of this function's ~20 call sites. Previously
    /// every call site did its own `checkpoints?.record(result)` right
    /// after obtaining `result` — one call per finalized mutant, but
    /// scattered, so a future new call site could forget it. Centralizing
    /// the write next to the one place `observations` (the thing that
    /// actually gets persisted, not `result`) is already in scope removes
    /// that possibility structurally, and is what makes storing raw
    /// `MutationObservations` — rather than the already-decided
    /// `MutationResult` — for the cache/checkpoint to later re-verify
    /// practical without threading a second return value through every
    /// caller and task-group element type in this file.
    func finalize(
        point: MutationPoint,
        sourceApplication: SourceApplicationOutcome? = nil,
        build: BuildObservation? = nil,
        coverage: CoverageObservation? = nil,
        test: SingleTestObservation? = nil,
        confirmations: [ConfirmationObservation] = [],
        infrastructureFailureDiagnosis: String? = nil,
        durationSeconds: Double,
        buildDurationSeconds: Double? = nil,
        testDurationSeconds: Double? = nil,
        confirmationDurationSeconds: Double? = nil
    ) async -> MutationResult {
        let ref = PlannedMutationRef.forPoint(point, planID: plan.planID, workUnitID: plan.workUnitID)
        let observations = MutationObservations(
            plannedMutation: ref,
            sourceApplication: sourceApplication,
            build: build,
            coverage: coverage,
            test: test,
            confirmations: confirmations,
            infrastructureFailureDiagnosis: infrastructureFailureDiagnosis
        )
        let record = MutationVerdictVerifier.verify(observations, policy: verificationPolicy)
        let result: MutationResult
        do {
            result = try MutationResult.projected(
                from: record, point: point, planID: plan.planID, workUnitID: plan.workUnitID,
                durationSeconds: durationSeconds, buildDurationSeconds: buildDurationSeconds,
                testDurationSeconds: testDurationSeconds, confirmationDurationSeconds: confirmationDurationSeconds
            )
        } catch {
            // Unreachable in practice: `ref` above was computed from `point`
            // via the identical call `projected` uses to check it, so they
            // can never disagree — but `projected` is intentionally not
            // `try!`-callable from outside `MutationModel`, and duplicating
            // its guarantee here as a crash would be worse than a loud,
            // honest infrastructure failure if some future change ever did
            // make this reachable.
            preconditionFailure("finalize's own ref must always match projected's recomputation: \(error)")
        }

        do {
            try await checkpoints?.record(
                observations, durationSeconds: durationSeconds, buildDurationSeconds: buildDurationSeconds,
                testDurationSeconds: testDurationSeconds, confirmationDurationSeconds: confirmationDurationSeconds
            )
        } catch {
            // Best-effort by design (score integrity never depends on a
            // checkpoint), but silent failure here quietly breaks the
            // "resume after interruption" contract without anyone noticing
            // until the machine actually goes down mid-run — surfacing it
            // both to stderr (for a human watching the run live) and to
            // `RunReport.operationalIssues` (for a reader of `report.json`
            // afterward) is worth more than either alone.
            let diagnosis = "checkpoint write failed for \(point.id): \(error)"
            FileHandle.standardError.write(Data("warning: \(diagnosis)\n".utf8))
            await operationalIssues.append(
                OperationalIssue(severity: .warning, kind: .checkpointWriteFailed, mutationID: point.id, diagnosis: diagnosis)
            )
        }
        if let resultCache, let resultCacheDigest {
            await resultCache.store(
                observations, durationSeconds: durationSeconds, buildDurationSeconds: buildDurationSeconds,
                testDurationSeconds: testDurationSeconds, confirmationDurationSeconds: confirmationDurationSeconds,
                for: MutationResultCache.Key(mutationID: point.id, contextDigest: resultCacheDigest)
            )
        }
        await progress?.recordCompletion()
        return result
    }

    /// `finalize` for the pre-classification infrastructure-failure early
    /// exits: no build/test observation exists yet, only a diagnosis (and,
    /// when the mutation was at least applied, its source evidence).
    func infrastructureFailureResult(
        point: MutationPoint,
        diagnosis: String,
        evidence: MutationEvidence? = nil,
        durationSeconds: Double,
        buildDurationSeconds: Double? = nil,
        testDurationSeconds: Double? = nil
    ) async -> MutationResult {
        await finalize(
            point: point,
            sourceApplication: evidence.map { .applied($0) },
            infrastructureFailureDiagnosis: diagnosis,
            durationSeconds: durationSeconds,
            buildDurationSeconds: buildDurationSeconds,
            testDurationSeconds: testDurationSeconds
        )
    }

    /// The source-level proof from the application, plus whatever the build and
    /// test stages added to it.
    func evidence(
        _ applied: AppliedMutation,
        artifact: BuildArtifact? = nil,
        activation: ActivationEvidence? = nil,
        buildCommand: CommandRecord? = nil,
        testCommand: CommandRecord? = nil,
        resultArtifact: String? = nil,
        crashConfirmation: CrashConfirmation? = nil,
        timeoutConfirmation: TimeoutConfirmation? = nil,
        testAttempts: [TestAttemptEvidence] = []
    ) -> MutationEvidence {
        MutationEvidence(
            sourceBeforeHash: applied.evidence.sourceBeforeHash,
            sourceAfterHash: applied.evidence.sourceAfterHash,
            sourceDiff: applied.evidence.sourceDiff,
            buildProductHash: artifact?.productHash,
            applicationEvidence: activation.map(MutationApplicationEvidence.isolated),
            buildCommand: artifact?.command ?? buildCommand,
            testCommand: testCommand,
            resultArtifact: resultArtifact,
            crashConfirmation: crashConfirmation,
            timeoutConfirmation: timeoutConfirmation,
            testAttempts: testAttempts
        )
    }

    /// Moves a result bundle somewhere it will outlive its sandbox.
    ///
    /// Recording a path under a directory this run is about to delete would be
    /// worse than recording nothing: `inspect` would offer evidence that is not
    /// there.
    ///
    /// `label`, when supplied, is folded into the destination filename —
    /// needed when a mutant is preserved more than once (wave-based early
    /// kill preserves one artifact per wave it survived, plus its final
    /// one): without a distinguishing label, a later wave's identically-named
    /// bundle would land at the same destination path as an earlier one.
    func preserve(_ url: URL?, for point: MutationPoint, in sandbox: URL, label: String? = nil) -> String? {
        guard let url, let artifactsRoot, FileManager.default.fileExists(atPath: url.path) else { return nil }

        let filename = label.map { "\($0)-\(url.lastPathComponent)" } ?? url.lastPathComponent
        let relative = point.id.rawValue + "/" + filename
        let destination = artifactsRoot.appendingPathComponent(relative)

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)

            // Copy rather than move when the bundle lives outside the sandbox:
            // there it may be a directory the adapter still owns.
            if url.resolvingSymlinksInPath().path.hasPrefix(sandbox.path + "/") {
                try FileManager.default.moveItem(at: url, to: destination)
            } else {
                try FileManager.default.copyItem(at: url, to: destination)
            }
        } catch {
            return nil
        }

        return relative
    }
}
