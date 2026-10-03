import Foundation

/// The only place a `VerifiedMutationRecord` is constructed, and — as of
/// ADR-0006 Stage 1 — the only place a mutation's outcome is *decided*.
///
/// `verify(_:)` is a pure function from `MutationObservations` (what
/// actually happened) to a verdict: no caller pre-computes an outcome and
/// hands it in (the previous `RawMutationAttempt.candidateOutcome` design
/// PR A–D used is gone). The judgment rules themselves are a faithful port
/// of `ResultClassifier`/`SchemataResultClassifier` (deleted from
/// `MutationExecution` in this stage) — this stage relocates and
/// restructures *where* the rules run, not what they decide; the existing,
/// extensive isolated-mode test suite (crash/flaky/timeout confirmation,
/// wave early-kill, etc.) is what proves that relocation preserved
/// behavior.
///
/// *Whether* to gather a confirmation observation (a retest, an
/// independent rebuild) is still a runner-level orchestration decision —
/// actually running one requires executing a build/test adapter, which the
/// verifier (in `MutationModel`, with no I/O capability at all) cannot do.
/// That decision is made from `MutationObservations.test`'s own raw
/// `TestRunResult.status`, never from an outcome this verifier already
/// decided — the runner asks "did this fail" and "is retesting configured
/// on", not "did the verifier call this a kill".

/// What confirmation (if any) a run's own policy requires for one
/// mutation's primary observation — see `MutationVerdictVerifier
/// .confirmationRequirement(for:policy:)`, the sole place this is decided.
public enum ConfirmationRequirement: Sendable, Equatable {
    case none
    case retestKilledMutant
    case confirmCrash
    case confirmTimeout
}

public enum MutationVerdictVerifier {
    /// Bumped whenever the rules below change in a way that could flip an
    /// outcome for previously-seen input. ADR-0005 PR C's cache-
    /// invalidation gate (`VerifiedVerdictReceipt`) reads this to auto-miss
    /// stale entries. Bumped to 2 for ADR-0006 Stage 1: the verifier now
    /// derives outcomes itself instead of reproducing a caller-supplied
    /// one, a real change to what "verified" means even though the
    /// underlying classification rules were ported, not rewritten. Bumped
    /// to 12: `verifySchemataChain` now groups STARTUP/HIT by process
    /// instead of requiring exactly one raw event — the identical
    /// `MutationObservations` that used to classify as
    /// `.infrastructureFailure` under a legitimate multi-process test run
    /// can now classify as `.survived`/`.killedByAssertion`, so a
    /// pre-bump cached verdict must never be reused as-is.
    public static let currentVersion = 12

    /// `verify(_:)` alone cannot tell a primary kill/crash that skipped its
    /// confirmation because the run's own configuration never enabled one
    /// apart from one whose `confirmations` were simply stripped out of an
    /// untrusted `MutationObservations` envelope — both look identical from
    /// the observations alone. This policy is that missing context: the
    /// same `Configuration.execution.retestKilledMutants`/
    /// `confirmCrashKills`/`confirmTimedOutMutants` flags the run itself
    /// was actually gated on, supplied by the caller so the verifier can
    /// require the confirmation those flags promise rather than trust
    /// whatever `confirmations` an untrusted envelope happens to contain.
    public struct VerdictVerificationPolicy: Codable, Sendable, Hashable {
        public let retestKilledMutants: Bool
        public let confirmCrashKills: Bool
        public let confirmTimedOutMutants: Bool

        public init(retestKilledMutants: Bool, confirmCrashKills: Bool, confirmTimedOutMutants: Bool) {
            self.retestKilledMutants = retestKilledMutants
            self.confirmCrashKills = confirmCrashKills
            self.confirmTimedOutMutants = confirmTimedOutMutants
        }

        /// Requires nothing — the pre-policy behavior. `verify(_:policy:)`
        /// takes no default, so this is never reached by omission; the
        /// right explicit choice for a test fixture that isn't exercising
        /// confirmation-policy enforcement. A real runner/cache/checkpoint
        /// call site should always pass the policy actually in effect for
        /// the run instead.
        public static let permissive = VerdictVerificationPolicy(
            retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: false
        )
    }

    public static func verify(_ observations: MutationObservations, policy: VerdictVerificationPolicy) -> VerifiedMutationRecord {
        let ref = observations.plannedMutation
        let proof = deriveProof(observations, ref: ref, policy: policy)
        return VerifiedMutationRecord(mutationRef: ref, proof: proof, verificationVersion: currentVersion)
    }

    /// What confirmation (if any) `policy` requires for `observations`,
    /// judged by classifying its primary observation exactly as `verify`
    /// itself would — before any confirmation is folded in. The single
    /// source of truth both `MutationRunner` and `SchemataMutationRunner`
    /// ask instead of each independently re-deriving "does this need a
    /// retest" from `policy`'s flags and the raw run status; a caller that
    /// diverged from this would risk gathering a confirmation `verify`
    /// would not actually credit, or skipping one it would require.
    ///
    /// Assumes `observations.confirmations` is empty — this answers "is a
    /// first confirmation needed", not "is another one needed after the
    /// first came back inconclusive" (a cascade, which stays a runner-level
    /// decision from that confirmation's own resulting status, unchanged).
    public static func confirmationRequirement(
        for observations: MutationObservations, policy: VerdictVerificationPolicy
    ) -> ConfirmationRequirement {
        guard
            case let .applied(evidence)? = observations.sourceApplication, evidence.provesSourceApplication,
            let build = observations.build, case let .succeeded(buildProductHash, _) = build.outcome,
            let test = observations.test,
            executionEvidenceProblem(
                sourceEvidence: evidence, buildProductHash: buildProductHash, testEvidence: test.applicationEvidence
            ) == nil
        else {
            return .none
        }

        let classification = classify(run: test.run, applicationEvidence: test.applicationEvidence, coverage: observations.coverage)
        switch classification.outcome {
        case .killedByAssertion where policy.retestKilledMutants:
            return .retestKilledMutant
        case .killedByCrash where policy.confirmCrashKills:
            return .confirmCrash
        case .timedOut where policy.confirmTimedOutMutants:
            return .confirmTimeout
        default:
            return .none
        }
    }

    /// Why a schemata attempt should be re-run in isolated mode instead of
    /// being scored from its own (unproven) schemata result — see
    /// `MutationVerdictVerifier.schemataIsolatedFallbackReason(for:)`, the
    /// sole place this is decided.
    ///
    /// Deliberately narrow: only the two failure shapes a passing test run
    /// genuinely cannot distinguish from "this mutation was simply never
    /// executed" (see that function's own doc comment for why the scope
    /// stops there). Every other `SchemataChainError` case — a duplicate
    /// STARTUP/HIT, an orphan HIT, a missing/ambiguous build receipt — is a
    /// real inconsistency, not a proof-of-execution gap, and stays
    /// `.infrastructureFailure` exactly as before.
    public enum SchemataIsolatedFallbackReason: String, Codable, Sendable, Hashable {
        case noStartup
        case noHit
    }

    /// Whether `observations`' own schemata attempt lacks *any* runtime
    /// activation proof (no STARTUP, or a STARTUP with no HIT) — the same
    /// shape a genuinely uncovered/never-executed mutation produces, which
    /// no isolated-mode equivalent proof exists to contradict. `nil` means
    /// no fallback is warranted: either the schemata chain already proved
    /// itself (`.survived`/`.killedByAssertion` will follow from `verify`
    /// unchanged), or the failure is a real inconsistency (a duplicate
    /// event, an orphan HIT, an ambiguous/missing build receipt) that
    /// isolated mode re-running the mutation would not explain away
    /// either — those stay `.infrastructureFailure`.
    ///
    /// Reuses `verifySchemataChain` itself — never a second, independent
    /// interpretation of the raw transcript — so this can never drift from
    /// what `verify(_:policy:)` would actually classify.
    ///
    /// Scoped to a *passing* test run only (Phase 1 of the no-HIT ->
    /// isolated-fallback design): a `.failed`/`.crashed`/`.timedOut` run
    /// with no HIT is a materially different question (was the failure
    /// even caused by this mutation at all?) that a future phase can
    /// address on its own evidence, not folded in here by widening this
    /// scope quietly.
    public static func schemataIsolatedFallbackReason(for observations: MutationObservations) -> SchemataIsolatedFallbackReason? {
        guard let test = observations.test, test.run.status == .passed else { return nil }
        guard case let .schemata(observation)? = test.applicationEvidence else { return nil }
        guard !provesSiteNeverReached(observation) else { return nil }
        do {
            _ = try verifySchemataChain(observation)
            return nil
        } catch SchemataChainError.noStartup {
            return .noStartup
        } catch SchemataChainError.noHit {
            return .noHit
        } catch {
            return nil
        }
    }

    // MARK: - Source application

    private static func deriveProof(
        _ obs: MutationObservations, ref: PlannedMutationRef, policy: VerdictVerificationPolicy
    ) -> VerdictProof {
        guard let sourceApplication = obs.sourceApplication else {
            return excluded(
                ref, outcome: .infrastructureFailure,
                diagnosis: obs.infrastructureFailureDiagnosis ?? "no observation reached even source application"
            )
        }

        switch sourceApplication {
        case let .notApplied(diagnosis):
            return excluded(ref, outcome: .notApplied, diagnosis: diagnosis)
        case let .applied(evidence):
            guard evidence.provesSourceApplication else {
                return excluded(
                    ref, outcome: .infrastructureFailure,
                    diagnosis: """
                    Source application was recorded, but the before/after hashes and source diff do not prove that an \
                    edit occurred.
                    """,
                    evidence: evidence
                )
            }
            return deriveAfterApplication(obs, ref: ref, evidence: evidence, policy: policy)
        }
    }

    // MARK: - Build

    private static func deriveAfterApplication(
        _ obs: MutationObservations, ref: PlannedMutationRef, evidence: MutationEvidence, policy: VerdictVerificationPolicy
    ) -> VerdictProof {
        // Coverage fast path: a baseline coverage map that knows this line
        // was never executed lets us classify without building at all.
        if obs.build == nil, let coverage = obs.coverage, !coverage.mutatedLineWasExecuted {
            return .noCoverage(NoCoverageProof(
                mutationRef: ref, sourceApplication: evidence, coverageSource: coverage.source,
                diagnosis: "The baseline suite never executed this line, so no test could have distinguished the mutation from the original. \(coverage.source) reports the mutated code was never reached."
            ))
        }

        guard let build = obs.build else {
            return excluded(
                ref, outcome: .infrastructureFailure,
                diagnosis: obs.infrastructureFailureDiagnosis ?? "the mutation was applied but no build was ever attempted"
            )
        }

        switch build.outcome {
        case let .failed(kind, diagnosis, _):
            switch kind {
            case .compilationError:
                return .unviable(BuildFailureProof(
                    mutationRef: ref,
                    diagnosis: "The mutant does not compile, so there was nothing to test: \(diagnosis)",
                    evidence: evidence
                ))
            case .infrastructure:
                return excluded(
                    ref, outcome: .infrastructureFailure,
                    diagnosis: "The build failed for reasons unrelated to the mutation: \(diagnosis)", evidence: evidence
                )
            case .timedOut:
                return excluded(
                    ref, outcome: .timedOut, diagnosis: "The mutant's build exceeded its time limit: \(diagnosis)", evidence: evidence
                )
            }
        case let .infrastructureFailure(diagnosis):
            return excluded(ref, outcome: .infrastructureFailure, diagnosis: diagnosis, evidence: evidence)
        case let .timedOut(diagnosis):
            return excluded(ref, outcome: .timedOut, diagnosis: diagnosis, evidence: evidence)
        case let .succeeded(buildProductHash, _):
            return deriveAfterBuild(obs, ref: ref, evidence: evidence, buildProductHash: buildProductHash, policy: policy)
        }
    }

    // MARK: - Test

    private static func deriveAfterBuild(
        _ obs: MutationObservations, ref: PlannedMutationRef, evidence: MutationEvidence, buildProductHash: String?,
        policy: VerdictVerificationPolicy
    ) -> VerdictProof {
        guard let test = obs.test else {
            return excluded(
                ref, outcome: .infrastructureFailure,
                diagnosis: obs.infrastructureFailureDiagnosis ?? "the build succeeded but no test observation was recorded",
                evidence: evidence
            )
        }

        let problem = executionEvidenceProblem(
            sourceEvidence: evidence, buildProductHash: buildProductHash, testEvidence: test.applicationEvidence
        )
        if let problem {
            return excluded(ref, outcome: .infrastructureFailure, diagnosis: problem, evidence: evidence)
        }

        var classification = classify(run: test.run, applicationEvidence: test.applicationEvidence, coverage: obs.coverage)

        for confirmation in obs.confirmations {
            classification = confirm(classification, confirmation: confirmation, primaryApplicationEvidence: test.applicationEvidence)
        }

        if let problem = missingRequiredConfirmationProblem(classification, confirmations: obs.confirmations, policy: policy) {
            classification = Classification(outcome: .infrastructureFailure, diagnosis: problem, decidingRun: classification.decidingRun)
        }

        return proof(for: classification, ref: ref, evidence: evidence, coverageSource: obs.coverage?.source)
    }

    /// `verify(_:)` sees only `MutationObservations`, not the run's own
    /// `Configuration.execution.retestKilledMutants`/`confirmCrashKills`
    /// flags — an untrusted envelope whose `confirmations` were simply
    /// stripped out looks identical to one where the run's own config never
    /// required a confirmation in the first place. `policy` closes that:
    /// a final `.killedByAssertion`/`.killedByCrash` reached while its
    /// policy flag is on must actually carry the confirmation of the
    /// matching kind the real run would have gathered, or it is not
    /// trusted. `.verifiedTimeout` needs no equivalent check — it is only
    /// ever *produced* by folding a `.timeout` confirmation in the first
    /// place (see `confirmTimeout`), so one is structurally guaranteed
    /// whenever this outcome is reached at all.
    private static func missingRequiredConfirmationProblem(
        _ classification: Classification, confirmations: [ConfirmationObservation], policy: VerdictVerificationPolicy
    ) -> String? {
        switch classification.outcome {
        case .killedByAssertion where policy.retestKilledMutants:
            guard confirmations.contains(where: { $0.kind == .kill }) else {
                return """
                This run's configuration requires a confirming retest for an assertion kill, but no .kill \
                confirmation was recorded.
                """
            }
        case .killedByCrash where policy.confirmCrashKills:
            guard confirmations.contains(where: { $0.kind == .crash }) else {
                return """
                This run's configuration requires a confirming rebuild for a crash kill, but no .crash \
                confirmation was recorded.
                """
            }
        default:
            break
        }
        return nil
    }

    /// `MutationEvidence.applicationEvidence` (the copy attached to the
    /// final proof) and `SingleTestObservation.applicationEvidence` (the
    /// copy the verifier actually classifies from) are independent `Codable`
    /// fields — the runner always constructs them from the same value, but
    /// nothing enforces that once `MutationObservations` round-trips
    /// through an untrusted cache/checkpoint envelope. Without this check,
    /// an edited entry could carry forged, proven-looking activation
    /// evidence on the test side while the evidence actually attached to
    /// the resulting proof stays whatever (even hollow) evidence sits on
    /// the source-application side — or vice versa. Also catches activation
    /// evidence whose own embedded hash disagrees with the build actually
    /// observed, which an edit could otherwise keep internally consistent
    /// between the two copies while still not matching reality.
    private static func executionEvidenceProblem(
        sourceEvidence: MutationEvidence, buildProductHash: String?, testEvidence: MutationApplicationEvidence?
    ) -> String? {
        guard sourceEvidence.applicationEvidence == testEvidence else {
            return """
            Source evidence and the test observation carry different activation evidence — this observation is \
            inconsistent and cannot be trusted.
            """
        }
        guard sourceEvidence.buildProductHash == buildProductHash else {
            return """
            The build product hash recorded in source evidence does not match the build observation — this \
            observation is inconsistent and cannot be trusted.
            """
        }

        if case let .isolated(activation)? = testEvidence {
            return isolatedActivationBuildProblem(activation, buildProductHash: buildProductHash)
        }

        return nil
    }

    /// Whether `activation`'s own embedded hash(es) actually match
    /// `buildProductHash` — an independently-observed build's product hash,
    /// never a value `activation` itself supplies. Shared between the
    /// primary path (`executionEvidenceProblem`, against
    /// `BuildObservation`'s hash) and timeout confirmation (against
    /// `ConfirmationObservation.confirmingBuildProductHash`) — both are the
    /// same question: does this self-reported activation evidence actually
    /// correspond to a build that was observed to happen, or could it name
    /// hashes that never came from any real build at all.
    private static func isolatedActivationBuildProblem(_ activation: ActivationEvidence, buildProductHash: String?) -> String? {
        switch activation {
        case let .buildProductDiffersFromBaseline(mutantHash, _):
            guard mutantHash == buildProductHash else {
                return """
                The activation evidence names a mutant product hash different from the observed build product — \
                this observation is inconsistent and cannot be trusted.
                """
            }
        case let .buildProductIdenticalToBaseline(hash):
            guard hash == buildProductHash else {
                return """
                The identical-product activation evidence does not match the observed build product — this \
                observation is inconsistent and cannot be trusted.
                """
            }
        }
        return nil
    }

    // MARK: - Classification (ported from ResultClassifier/SchemataResultClassifier)

    /// `decidingRun` is whichever `TestRunResult` actually produced this
    /// classification — the primary run, or a confirmation's run once a
    /// confirmation changes the outcome. `proof(for:...)` reads its summary
    /// straight from here rather than a `testSummary` threaded in
    /// separately, so a confirmation that flips the final outcome (a
    /// batch-attributed timeout trusted as a kill, say) attaches the run
    /// that actually decided it, not the original timed-out run's summary.
    private struct Classification {
        let outcome: MutationOutcome
        let diagnosis: String
        let decidingRun: TestRunResult?
    }

    private static func classify(
        run: TestRunResult,
        applicationEvidence: MutationApplicationEvidence?,
        coverage: CoverageObservation?
    ) -> Classification {
        switch run.status {
        case .failed:
            if let unproven = unprovenActivation(applicationEvidence) {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "The tests failed (\(run.diagnosis)), but \(unproven) — a failure cannot be credited as a kill without proof the mutation caused it.",
                    decidingRun: run
                )
            }
            return Classification(outcome: .killedByAssertion, diagnosis: killedByAssertionDiagnosis(run), decidingRun: run)

        case .crashed:
            if let unproven = unprovenActivation(applicationEvidence) {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "The test runner crashed (\(run.diagnosis)), but \(unproven) — a crash cannot be credited as a kill without proof the mutation caused it.",
                    decidingRun: run
                )
            }
            return Classification(
                outcome: .killedByCrash,
                diagnosis: "The mutant killed the test runner rather than failing an assertion: \(run.diagnosis)",
                decidingRun: run
            )

        case .timedOut:
            return Classification(
                outcome: .timedOut,
                diagnosis: "The mutant's tests did not finish within their limit, so the suite never got to judge it: \(run.diagnosis)",
                decidingRun: run
            )

        case .infrastructureFailure:
            return Classification(
                outcome: .infrastructureFailure, diagnosis: "The test run produced no verdict for this mutant: \(run.diagnosis)", decidingRun: run
            )

        case .passed:
            return classifyPassing(run: run, applicationEvidence: applicationEvidence, coverage: coverage)
        }
    }

    private static func classifyPassing(
        run: TestRunResult,
        applicationEvidence: MutationApplicationEvidence?,
        coverage: CoverageObservation?
    ) -> Classification {
        let passed = run.summary.map { "All \($0.total) tests passed" } ?? "The tests passed"

        switch applicationEvidence {
        case let .schemata(observation)?:
            let chain = Result { try verifySchemataChain(observation) }
            if let coverage, !coverage.mutatedLineWasExecuted {
                if case .success = chain {
                    return Classification(
                        outcome: .infrastructureFailure,
                        diagnosis: """
                        \(passed), but \(coverage.source) reports the mutated code was never executed, \
                        while the verified chain proves the mutation was built, selected, and hit in this \
                        exact run — a genuine contradiction between coverage and runtime evidence, not \
                        something either signal alone can resolve.
                        """,
                        decidingRun: run
                    )
                }
                return Classification(
                    outcome: .noCoverage, diagnosis: "\(passed), but \(coverage.source) reports the mutated code was never executed.", decidingRun: run
                )
            }
            guard case .success = chain else {
                if provesSiteNeverReached(observation) {
                    return Classification(
                        outcome: .noCoverage,
                        diagnosis: "\(passed), and the MutantKit runtime proves it was loaded in the test process, but the mutated code was never reached.",
                        decidingRun: run
                    )
                }
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "\(passed), but \(schemataChainDiagnosis(chain))",
                    decidingRun: run
                )
            }
            return Classification(
                outcome: .survived,
                diagnosis: "\(passed) with the mutation proven active and hit in this run, so nothing in the suite distinguishes this change from the original.",
                decidingRun: run
            )

        case .isolated, nil:
            if let coverage, !coverage.mutatedLineWasExecuted {
                return Classification(
                    outcome: .noCoverage, diagnosis: "\(passed), but \(coverage.source) reports the mutated code was never executed.", decidingRun: run
                )
            }
            guard case let .isolated(activation)? = applicationEvidence else {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "\(passed), but the build produced no product hash, so there is no proof the mutation reached the code under test; a passing suite is not evidence without it.",
                    decidingRun: run
                )
            }
            guard activation.provesActivation else {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "\(passed), but the mutant's build product is identical to the baseline's, so the mutation never reached the code under test and this result proves nothing.",
                    decidingRun: run
                )
            }
            return Classification(
                outcome: .survived,
                diagnosis: "\(passed) with the mutation active in the build product, so nothing in the suite distinguishes this change from the original.",
                decidingRun: run
            )
        }
    }

    private static func unprovenActivation(_ applicationEvidence: MutationApplicationEvidence?) -> String? {
        switch applicationEvidence {
        case let .isolated(activation)?:
            if activation.provesActivation { return nil }
            return "the mutant's build product is identical to the baseline's, so the mutation never reached the code under test"
        case let .schemata(observation)?:
            let chain = Result { try verifySchemataChain(observation) }
            if case .success = chain { return nil }
            return schemataChainDiagnosis(chain)
        case nil:
            return "the build produced no product hash, so there is no proof the mutation reached the code under test"
        }
    }

    // MARK: - Schemata chain verification (ADR-0006 Stage 2)

    /// One process's own complete, unambiguous proof: a STARTUP that loaded
    /// the expected unit/image under this run, and the one HIT that same
    /// process recorded for the expected mutation.
    private struct VerifiedProcessSchemataChain {
        let startup: RuntimeStartupEvent
        let hit: RuntimeHitEvent
    }

    /// A compilation unit, independently proven by the build receipt to
    /// land in a real built image, plus at least one complete per-process
    /// STARTUP -> HIT chain proving that unit's mutation was selected and
    /// hit in this exact run.
    ///
    /// `processes` is never empty (`verifySchemataChain` throws rather than
    /// construct one with zero) — but it is not required to hold exactly
    /// one, either. A single `mutantkit run` invocation can genuinely
    /// spawn more than one test process for the identical build (the test
    /// runner's own multi-process execution model, not a MutantKit
    /// decision) — every one of those processes independently loading the
    /// same image and independently hitting the same mutation site is
    /// *more* proof of activation, never ambiguity. What must stay unique
    /// is each *process's own* STARTUP and HIT (`SchemataChainError
    /// .duplicateStartup`/`.duplicateHit`) and the semantic identity every
    /// chain is built from (unit/image/token/embedding/run) — never how
    /// many processes ran it.
    private struct VerifiedSchemataChain {
        let unit: CompilationUnitReceipt
        let image: BuiltImageReceipt
        let processes: [VerifiedProcessSchemataChain]
    }

    private enum SchemataChainError: Error, CustomStringConvertible {
        case noBuildReceipt
        case nonUniqueCompilationUnit
        case nonUniqueBuiltImage
        case noStartup
        case noHit
        case duplicateStartup(processID: Int32)
        case duplicateHit(processID: Int32)
        case orphanHit(processID: Int32)

        var description: String {
            switch self {
            case .noBuildReceipt:
                "the build-time compilation-unit-to-image mapping could not be proven"
            case .nonUniqueCompilationUnit:
                "the build receipt does not name exactly one compilation unit matching this mutation's own identity"
            case .nonUniqueBuiltImage:
                "the build receipt does not name exactly one built image for the matched compilation unit's target"
            case .noStartup:
                "the transcript contains no STARTUP event matching this run's own expectation and the receipt's real image"
            case .noHit:
                "the transcript contains no HIT event from any process that started up under this run's own expectation"
            case let .duplicateStartup(processID):
                "process \(processID) recorded more than one STARTUP event matching this run's own expectation — the runtime's own at-most-once contract was violated"
            case let .duplicateHit(processID):
                "process \(processID) recorded more than one HIT event matching this run's own expectation — the runtime's own at-most-once contract was violated"
            case let .orphanHit(processID):
                "process \(processID) recorded a HIT event with no matching STARTUP in that same process — an inconsistent transcript"
            }
        }
    }

    /// Requires exactly one candidate, or throws — the shared discipline
    /// every stage of `verifySchemataChain` uses: zero candidates and more
    /// than one are both refused identically, never resolved by
    /// `.first`/`.max` picking (ADR-0006 Finding 3).
    private static func exactlyOne<T>(_ candidates: [T], or error: SchemataChainError) throws -> T {
        guard candidates.count == 1, let only = candidates.first else { throw error }
        return only
    }

    /// Builds the one, fully-proven chain from raw observations alone —
    /// `PlannedMutationRef -> sourceEmbeddingID -> CompilationUnitReceipt ->
    /// BuiltImageReceipt/architecture/LC_UUID -> {STARTUP -> HIT}+`. The
    /// only place this proof chain is ever constructed (ADR-0006 Stage 2):
    /// `SchemataMutationRunner` collects `observation` and decides nothing.
    ///
    /// Every raw STARTUP/HIT event not matching the expected semantic
    /// identity (run/unit/embedding/token/image) is treated as noise from
    /// an unrelated compilation unit or mutation sharing the same
    /// transcript — filtered out before any cardinality check, never
    /// itself a source of ambiguity. What remains is grouped *by process*:
    /// a real test invocation can legitimately spawn more than one process
    /// for the identical build (see `VerifiedSchemataChain`'s own doc
    /// comment), so uniqueness is enforced per process, not across the
    /// whole raw transcript.
    private static func verifySchemataChain(_ observation: SchemataExecutionObservation) throws -> VerifiedSchemataChain {
        guard let receipt = observation.buildReceipt else { throw SchemataChainError.noBuildReceipt }
        let expectation = observation.expectation

        let unit = try exactlyOne(
            receipt.compilationUnits.filter {
                $0.compilationUnitID == expectation.compilationUnitID && $0.sourceEmbeddingID == expectation.sourceEmbeddingID
            },
            or: .nonUniqueCompilationUnit
        )
        let image = try exactlyOne(receipt.images.filter { $0.buildTarget == unit.buildTarget }, or: .nonUniqueBuiltImage)

        func matchesExpectedIdentity(
            runID: RunID, compilationUnitID: CompilationUnitID, sourceEmbeddingID: SHA256Digest,
            token: SchemataSelectorToken, imageUUID: ImageUUID
        ) -> Bool {
            runID == expectation.runID && compilationUnitID == unit.compilationUnitID && sourceEmbeddingID == unit.sourceEmbeddingID
                && token == expectation.selectorToken && image.slices.contains { $0.imageUUID == imageUUID }
        }

        // Both collected before any absence is classified: a transcript
        // that has a HIT but genuinely no matching STARTUP in that same
        // process (an inconsistent transcript, `.orphanHit`) must never be
        // misreported as `.noStartup` — which Group 2's isolated-fallback
        // routing (`MutationVerdictVerifier.schemataIsolatedFallbackReason`)
        // treats as "legitimately never executed" and would otherwise
        // silently paper over a real inconsistency instead of failing
        // closed.
        let matchingStartups = observation.transcript.records.compactMap { record -> RuntimeStartupEvent? in
            guard case let .startup(event) = record else { return nil }
            return event
        }.filter {
            matchesExpectedIdentity(
                runID: $0.runID, compilationUnitID: $0.compilationUnitID, sourceEmbeddingID: $0.sourceEmbeddingID,
                token: $0.token, imageUUID: $0.imageUUID
            )
        }
        let matchingHits = observation.transcript.records.compactMap { record -> RuntimeHitEvent? in
            guard case let .hit(event) = record else { return nil }
            return event
        }.filter {
            matchesExpectedIdentity(
                runID: $0.runID, compilationUnitID: $0.compilationUnitID, sourceEmbeddingID: $0.sourceEmbeddingID,
                token: $0.token, imageUUID: $0.imageUUID
            )
        }

        let startupsByProcess = Dictionary(grouping: matchingStartups, by: \.processID)
        let hitsByProcess = Dictionary(grouping: matchingHits, by: \.processID)

        for processID in startupsByProcess.keys.sorted() where startupsByProcess[processID]!.count > 1 {
            throw SchemataChainError.duplicateStartup(processID: processID)
        }
        for processID in hitsByProcess.keys.sorted() where hitsByProcess[processID]!.count > 1 {
            throw SchemataChainError.duplicateHit(processID: processID)
        }
        let startupByProcess = startupsByProcess.compactMapValues(\.first)
        for processID in hitsByProcess.keys.sorted() where startupByProcess[processID] == nil {
            throw SchemataChainError.orphanHit(processID: processID)
        }

        guard !matchingStartups.isEmpty else { throw SchemataChainError.noStartup }

        let processes = hitsByProcess.keys.sorted().map { processID in
            VerifiedProcessSchemataChain(startup: startupByProcess[processID]!, hit: hitsByProcess[processID]!.first!)
        }
        guard !processes.isEmpty else { throw SchemataChainError.noHit }

        return VerifiedSchemataChain(unit: unit, image: image, processes: processes)
    }

    /// Whether the chain fails *only* for lack of a STARTUP or HIT while the
    /// runtime's own LOADED record proves it was loaded, under this run's
    /// token, into the exact image the receipt names for this mutation.
    /// Registration and the HIT record both fire the first time a mutated
    /// site in that image runs, so this proves the site was never reached
    /// rather than that the runtime failed to report.
    private static func provesSiteNeverReached(_ observation: SchemataExecutionObservation) -> Bool {
        do {
            _ = try verifySchemataChain(observation)
            return false
        } catch SchemataChainError.noStartup, SchemataChainError.noHit {
            let expectation = observation.expectation
            guard let receipt = observation.buildReceipt,
                  let unit = try? exactlyOne(
                      receipt.compilationUnits.filter {
                          $0.compilationUnitID == expectation.compilationUnitID && $0.sourceEmbeddingID == expectation.sourceEmbeddingID
                      },
                      or: .nonUniqueCompilationUnit
                  ),
                  let image = try? exactlyOne(receipt.images.filter { $0.buildTarget == unit.buildTarget }, or: .nonUniqueBuiltImage)
            else { return false }
            return observation.transcript.records.contains { record in
                guard case let .loaded(event) = record else { return false }
                return event.runID == expectation.runID && event.token == expectation.selectorToken
                    && image.slices.contains { $0.imageUUID == event.imageUUID }
            }
        } catch {
            return false
        }
    }

    private static func schemataChainDiagnosis(_ chain: Result<VerifiedSchemataChain, Error>) -> String {
        guard case let .failure(error) = chain else {
            return "the schemata evidence does not prove this mutation was built, selected, and hit in this run"
        }
        return "the schemata chain could not be verified: \((error as? SchemataChainError)?.description ?? "\(error)")"
    }

    // MARK: - Confirmation (ported from ResultClassifier.confirmKill/confirmCrash/confirmTimeout)

    /// Each confirmation kind only means something applied on top of the
    /// specific outcome its own primary classification would have produced
    /// — `.kill` confirms a `.killedByAssertion`, `.crash` a `.killedByCrash`,
    /// `.timeout` a `.timedOut`. `MutationObservations` is public `Codable`
    /// and re-decoded as an untrusted envelope by the cache/checkpoint, so a
    /// hand-edited or corrupted `confirmations` array — a `.kill`
    /// confirmation attached to what actually classified as `.survived` or
    /// `.infrastructureFailure` — must not be able to promote an
    /// unconfirmed/wrong-shaped classification to a kill just by being
    /// present in the list. Folding them unconditionally in order (the
    /// previous behavior) let it do exactly that.
    private static func confirm(
        _ original: Classification, confirmation: ConfirmationObservation, primaryApplicationEvidence: MutationApplicationEvidence?
    ) -> Classification {
        let expected: MutationOutcome
        switch confirmation.kind {
        case .kill: expected = .killedByAssertion
        case .crash: expected = .killedByCrash
        case .timeout: expected = .timedOut
        }

        guard original.outcome == expected else {
            return Classification(
                outcome: .infrastructureFailure,
                diagnosis: """
                A \(confirmation.kind) confirmation was recorded, but the run it confirms \
                classified as \(original.outcome.rawValue), not \(expected.rawValue) — this \
                observation is inconsistent and cannot be trusted.
                """,
                decidingRun: original.decidingRun
            )
        }

        if case let .schemata(confirmingObservation)? = confirmation.applicationEvidence {
            let problem = schemataConfirmationChainProblem(
                confirmingObservation, primaryApplicationEvidence: primaryApplicationEvidence
            )
            if let problem {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "\(original.diagnosis) A confirmation was recorded, but \(problem)",
                    decidingRun: confirmation.run
                )
            }
        }

        switch confirmation.kind {
        case .kill: return confirmKill(original, confirmation: confirmation)
        case .crash: return confirmCrash(original, confirmation: confirmation)
        case .timeout: return confirmTimeout(original, confirmation: confirmation)
        }
    }

    /// Every way a schemata confirmation's own chain fails to independently
    /// prove itself — checked before any kind-specific confirm rule ever
    /// sees it, so a confirmation is never credited on the strength of the
    /// run it is confirming (ADR-0006 Stage 3): it must carry its own
    /// unique STARTUP -> HIT chain, under a `RunID` that is genuinely
    /// different from the primary observation's, never a replay.
    private static func schemataConfirmationChainProblem(
        _ confirmingObservation: SchemataExecutionObservation, primaryApplicationEvidence: MutationApplicationEvidence?
    ) -> String? {
        if case let .schemata(primary)? = primaryApplicationEvidence, primary.expectation.runID == confirmingObservation.expectation.runID {
            return """
            the confirmation reused the original run's own RunID — a confirmation must be a genuinely independent \
            run, never a replay.
            """
        }
        let chain = Result { try verifySchemataChain(confirmingObservation) }
        guard case .success = chain else {
            return "the confirmation's own schemata chain could not be verified: \(schemataChainDiagnosis(chain))"
        }
        return nil
    }

    /// `confirmation.originalFailingTests` is not consulted here: it is a
    /// caller-supplied duplicate of the primary run's own facts, and
    /// `MutationObservations` decodes it as untrusted — a corrupted or
    /// hand-edited entry could set it to whatever it wants without touching
    /// the primary run at all. `original.decidingRun`'s own `summary` is the
    /// actual primary run this confirmation is confirming, so that is what
    /// gets compared against.
    private static func confirmKill(_ original: Classification, confirmation: ConfirmationObservation) -> Classification {
        let confirmingRun = confirmation.run
        guard confirmingRun.status == .failed else {
            return Classification(
                outcome: .flaky,
                diagnosis: """
                \(original.diagnosis) A second run of the identical, already-built mutant did \
                not fail the same way (\(confirmingRun.status.rawValue)): \(confirmingRun.diagnosis) \
                The suite disagrees with itself, so this is not a proven kill.
                """,
                decidingRun: confirmingRun
            )
        }

        guard
            let originalFailingTests = original.decidingRun?.summary?.failingTests,
            let confirmingFailingTests = confirmingRun.summary?.failingTests
        else {
            return Classification(
                outcome: .flaky,
                diagnosis: """
                \(original.diagnosis) A second run of the identical, already-built mutant also \
                failed, but which test caught it could not be compared between the two runs — \
                the runner reported no per-test breakdown for at least one of them, so there is \
                no way to prove the retest caught the same test rather than a different, \
                unrelated flake. Without that proof this is not a confirmed kill.
                """,
                decidingRun: confirmingRun
            )
        }

        guard Set(originalFailingTests) == Set(confirmingFailingTests) else {
            return Classification(
                outcome: .flaky,
                diagnosis: """
                \(original.diagnosis) A second run of the identical, already-built mutant also \
                failed, but not on exactly the same test(s) as the first run \
                (originally caught by \(originalFailingTests.joined(separator: ", ")); the retest \
                was caught by \(confirmingFailingTests.joined(separator: ", "))) — the suite is \
                flaking rather than consistently catching this mutation the same way, so this is \
                not a confirmed kill.
                """,
                decidingRun: confirmingRun
            )
        }

        return Classification(
            outcome: .killedByAssertion,
            diagnosis: "\(original.diagnosis) Confirmed by a second run of the identical mutant, failing the same test(s).",
            decidingRun: confirmingRun
        )
    }

    /// `confirmation.originalDiagnosis` is not consulted here, for the same
    /// reason `confirmKill` does not read `originalFailingTests` — see its
    /// own doc comment. `original.decidingRun`'s own `diagnosis` is used
    /// instead.
    private static func confirmCrash(_ original: Classification, confirmation: ConfirmationObservation) -> Classification {
        let confirmingRun = confirmation.run
        guard confirmingRun.status == .crashed else {
            return Classification(
                outcome: .flaky,
                diagnosis: """
                \(original.diagnosis) An independent rebuild of the identical mutant did not \
                crash the same way (\(confirmingRun.status.rawValue)): \(confirmingRun.diagnosis) \
                The pipeline disagrees with itself, so this is not a proven kill.
                """,
                decidingRun: confirmingRun
            )
        }

        let originalDiagnosis = original.decidingRun?.diagnosis ?? ""
        let normalizedOriginal = originalDiagnosis.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConfirming = confirmingRun.diagnosis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedOriginal == normalizedConfirming else {
            return Classification(
                outcome: .flaky,
                diagnosis: """
                \(original.diagnosis) An independent rebuild of the identical mutant crashed \
                again, but not for the same reason (originally: \(originalDiagnosis); the rebuild: \
                \(confirmingRun.diagnosis)) — the pipeline is crashing inconsistently rather than \
                reproducing the same failure, so this is not a proven kill.
                """,
                decidingRun: confirmingRun
            )
        }

        return Classification(
            outcome: .killedByCrash,
            diagnosis: "\(original.diagnosis) Confirmed by an independent rebuild of the identical mutant, crashing the same way.",
            decidingRun: confirmingRun
        )
    }

    /// `confirmation.activation` is self-reported the same way the primary
    /// path's `SingleTestObservation.applicationEvidence` is, but unlike
    /// the primary path — cross-checked against an independently-observed
    /// `BuildObservation` by `executionEvidenceProblem` — nothing tied a
    /// timeout confirmation's activation to a build this confirmation's own
    /// rebuild was actually observed to produce. A forged `activation`
    /// naming a self-consistent (non-empty, distinct) hash pair that never
    /// came from any real build could still read as proven. This is that
    /// missing cross-check, using `confirmation.confirmingBuildProductHash`
    /// the same way the primary path uses `BuildObservation`'s hash.
    private static func confirmationActivationBuildProblem(_ confirmation: ConfirmationObservation) -> String? {
        guard let activation = confirmation.activation else { return nil }
        return isolatedActivationBuildProblem(activation, buildProductHash: confirmation.confirmingBuildProductHash)
    }

    private static func confirmTimeout(_ original: Classification, confirmation: ConfirmationObservation) -> Classification {
        let confirmingRun = confirmation.run
        if let problem = confirmationActivationBuildProblem(confirmation) {
            return Classification(
                outcome: .infrastructureFailure,
                diagnosis: "\(original.diagnosis) An independent rebuild's activation evidence is inconsistent with its own build: \(problem)",
                decidingRun: confirmingRun
            )
        }
        switch confirmingRun.status {
        case .timedOut:
            if let unproven = unprovenActivation(confirmation.applicationEvidence) {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "\(original.diagnosis) An independent rebuild timed out again, but \(unproven) — a timeout cannot be credited as a verified kill without proof the mutation caused it.",
                    decidingRun: confirmingRun
                )
            }
            return Classification(
                outcome: .verifiedTimeout,
                diagnosis: "\(original.diagnosis) Confirmed by an independent rebuild of the identical mutant: timed out again under the same limit.",
                decidingRun: confirmingRun
            )
        case .infrastructureFailure:
            return Classification(
                outcome: .infrastructureFailure,
                diagnosis: "\(original.diagnosis) The timeout could not be confirmed: the independent rebuild could not execute (\(confirmingRun.diagnosis)).",
                decidingRun: confirmingRun
            )
        case .passed, .failed, .crashed:
            // Not `confirmation.wasBatchAttributed`: that is a caller-
            // supplied duplicate of the primary run's own
            // `isBatchAttributedTimeout`, decoded as untrusted the same way
            // `originalFailingTests`/`originalDiagnosis` were — a corrupted
            // or hand-edited entry could flip it to `true` for a primary
            // run that was never batch-attributed, promoting what should
            // stay `.flaky` into a trusted kill/survived/crash outcome via
            // `trustedTimeoutOutcome`. The primary run's own status and
            // flag are the only trustworthy source for this.
            guard original.decidingRun?.status == .timedOut, original.decidingRun?.isBatchAttributedTimeout == true else {
                return Classification(
                    outcome: .flaky,
                    diagnosis: """
                    \(original.diagnosis) An independent rebuild of the identical mutant did not \
                    time out the same way (\(confirmingRun.status.rawValue)): \(confirmingRun.diagnosis) \
                    The pipeline disagrees with itself, so this is not a proven kill.
                    """,
                    decidingRun: confirmingRun
                )
            }
            return trustedTimeoutOutcome(original: original, confirmation: confirmation)
        }
    }

    private static func trustedTimeoutOutcome(original: Classification, confirmation: ConfirmationObservation) -> Classification {
        let confirmingRun = confirmation.run
        switch confirmingRun.status {
        case .passed:
            let passing = classifyPassing(run: confirmingRun, applicationEvidence: confirmation.applicationEvidence, coverage: nil)
            return Classification(
                outcome: passing.outcome,
                diagnosis: "\(original.diagnosis) Not confirmed as a timeout: an independent rebuild of the identical mutant ran to completion instead. \(passing.diagnosis)",
                decidingRun: confirmingRun
            )
        case .failed:
            if let unproven = unprovenActivation(confirmation.applicationEvidence) {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "\(original.diagnosis) An independent rebuild's tests failed (\(confirmingRun.diagnosis)), but \(unproven) — a failure cannot be credited as a kill without proof the mutation caused it.",
                    decidingRun: confirmingRun
                )
            }
            return Classification(
                outcome: .killedByAssertion,
                diagnosis: "\(original.diagnosis) Not confirmed as a timeout: an independent rebuild of the identical mutant ran to completion instead. \(killedByAssertionDiagnosis(confirmingRun))",
                decidingRun: confirmingRun
            )
        case .crashed:
            if let unproven = unprovenActivation(confirmation.applicationEvidence) {
                return Classification(
                    outcome: .infrastructureFailure,
                    diagnosis: "\(original.diagnosis) An independent rebuild's test runner crashed (\(confirmingRun.diagnosis)), but \(unproven) — a crash cannot be credited as a kill without proof the mutation caused it.",
                    decidingRun: confirmingRun
                )
            }
            return Classification(
                outcome: .killedByCrash,
                diagnosis: "\(original.diagnosis) Not confirmed as a timeout: an independent rebuild of the identical mutant crashed the test runner instead of hanging: \(confirmingRun.diagnosis)",
                decidingRun: confirmingRun
            )
        case .timedOut, .infrastructureFailure:
            preconditionFailure("trustedTimeoutOutcome is only reached for .passed/.failed/.crashed")
        }
    }

    private static func killedByAssertionDiagnosis(_ run: TestRunResult) -> String {
        guard let summary = run.summary else {
            return """
            A test assertion failed on this mutant, so it was caught. The runner reported no per-test breakdown, \
            so which test caught it is unknown.
            """
        }
        let caught = summary.failingTests.prefix(3).joined(separator: ", ")
        let base = "\(summary.failed) of \(summary.total) tests failed on this mutant"
        guard !caught.isEmpty else { return base + "." }
        let more = summary.failingTests.count > 3 ? " and \(summary.failingTests.count - 3) more" : ""
        return base + ", caught by \(caught)\(more)."
    }

    // MARK: - Classification -> VerdictProof

    private static func proof(
        for classification: Classification, ref: PlannedMutationRef, evidence: MutationEvidence,
        coverageSource: String? = nil
    ) -> VerdictProof {
        switch classification.outcome {
        case .killedByAssertion, .killedByCrash, .verifiedTimeout, .survived:
            return .executed(ExecutedMutationProof(
                mutationRef: ref, outcome: classification.outcome, evidence: evidence,
                testSummary: classification.decidingRun?.summary, diagnosis: classification.diagnosis
            ))
        case .noCoverage:
            return .noCoverage(NoCoverageProof(
                mutationRef: ref, sourceApplication: evidence, coverageSource: coverageSource, diagnosis: classification.diagnosis
            ))
        case .unviable:
            return .unviable(BuildFailureProof(mutationRef: ref, diagnosis: classification.diagnosis, evidence: evidence))
        case .timedOut, .flaky, .notApplied, .baselineMismatch, .infrastructureFailure, .skipped:
            return excluded(ref, outcome: classification.outcome, diagnosis: classification.diagnosis, evidence: evidence)
        }
    }

    private static func excluded(
        _ ref: PlannedMutationRef, outcome: MutationOutcome, diagnosis: String, evidence: MutationEvidence? = nil
    ) -> VerdictProof {
        .excluded(ExclusionProof(mutationRef: ref, outcome: outcome, diagnosis: diagnosis, evidence: evidence))
    }
}
