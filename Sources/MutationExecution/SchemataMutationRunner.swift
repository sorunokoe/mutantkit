import Foundation
import MutationModel
import SwiftFrontend

/// The schemata-backend orchestration loop — sibling to `MutationRunner`,
/// not a replacement for it. `MutationRunner` is never touched or called
/// from here; the two are combined by the CLI layer (`SchemataRunOrchestration`),
/// not by either engine type itself.
///
/// One sandbox and one build per chunk, one fresh test process per embedded
/// mutation — see the plan this was built from (ADR-0004's schemata
/// production-integration effort) for why: `swift test` leaves a
/// `swiftpm-testing-helper` descendant outside the launched process's own
/// group, so the harness can never know the real test process's PID in
/// advance. Every run therefore goes through the same nonce-primary
/// evidence protocol `SchemataEvidenceCollector` already provides for the
/// Xcode case — not Xcode-specific plumbing reused opportunistically, but
/// the one mechanism both backends need.
///
/// Chunks run concurrently, bounded by `workers` (mirrors isolated mode's
/// own `Configuration.execution.resolvedWorkerCount()` convention — see
/// that init parameter's own doc comment) — no checkpointing, no
/// cross-run cache participation. `workers: 1` (the default) reproduces
/// v1's original fully-sequential behaviour exactly, including entry
/// order, since a chunk is only ever launched once the previous one has
/// fully returned.
///
/// `public` (ADR-0006 Stage 3): schemata scoring is re-enabled, so
/// `SchemataRunOrchestration` (`CLI`) constructs and calls one directly
/// for whatever `SchemataChunkPlanner` embeds — everything else still
/// routes to isolated fallback.
public struct SchemataMutationRunner: Sendable {
    /// What one full run produced. Raw pieces, not a `RunReport` — the CLI
    /// layer combines this with isolated-fallback results before building
    /// one report.
    public struct Outcome: Sendable {
        public let baseline: BaselineRecord
        /// One aggregate `MutationResult` per mutation, for display and
        /// for feeding a `RunReport` the same way isolated mode's results
        /// do. For a mutation embedded into more than one target, this is
        /// `multiTargetVerdicts`'s own aggregation policy's winner (kill
        /// in any target wins) — never a value computed separately from
        /// it, so `results` and `multiTargetVerdicts` can never disagree
        /// about which outcome won.
        public let results: [MutationResult]
        /// Every target's own verdict for every mutation, preserved in
        /// full (ADR-0006 Stage 1) — nothing about a losing target's
        /// evidence is discarded here, unlike ADR-0005 PR F's
        /// `mergeMultiTargetResults`, which this replaces.
        public let multiTargetVerdicts: [MultiTargetVerdict]
        /// Every mutation this run attempted through schemata but could not
        /// score, for either of two structurally different reasons (see
        /// `SchemataFallbackReason`) — excluded entirely from
        /// `results`/`multiTargetVerdicts`: no schemata `TargetRecord` for
        /// this `MutationID`, for *any* of its target placements, was kept
        /// (`groupByMutation`'s own all-or-nothing rule — see `run()`).
        /// `SchemataRunOrchestration` re-runs each of these through
        /// isolated `MutationRunner` instead; this runner never scores
        /// them itself.
        public let isolatedFallbacks: [DynamicFallback]
        /// One aggregate event per chunk whose shared build genuinely
        /// failed to compile (ADR-0008 Addendum 4's fan-out/observability
        /// requirement) — never one event per affected `MutationID`. Every
        /// `MutationID` a failed chunk's build covered still appears,
        /// individually, in `isolatedFallbacks` above with reason
        /// `.sharedChunkBuildFailure`; this array exists only so a
        /// systemic problem (one bad chunk taking down many `MutationID`s
        /// at once) is visible as the single widescale event it actually
        /// is, not diluted into what would otherwise look like many
        /// unremarkable individual fallbacks with no visible shared cause.
        public let sharedChunkBuildFailureEvents: [SharedChunkBuildFailureEvent]
        /// The identical fan-out/observability shape as
        /// `sharedChunkBuildFailureEvents`, for `SchemataInfrastructureFallbackEvent`
        /// instead — currently, a chunk whose own build succeeded but whose
        /// build receipt could not be resolved (`.buildReceiptUnavailable`).
        /// Every `MutationID` such a chunk covered still appears,
        /// individually, in `isolatedFallbacks` above.
        public let infrastructureFallbackEvents: [SchemataInfrastructureFallbackEvent]
    }

    /// One shared schemata chunk build (initial or mid-chunk recovery
    /// rebuild) that genuinely failed to compile — ADR-0008 Addendum 4's
    /// required aggregate event, emitted once per failed build attempt,
    /// never once per affected `MutationID`. `diagnosticReference` is the
    /// build adapter's own already-computed `BuildFailure.diagnosis` (a
    /// stable, deterministic summary — not the full, much longer raw
    /// compiler `output`), the same field every other build-failure
    /// diagnosis in this codebase already surfaces as its explanation.
    public struct SharedChunkBuildFailureEvent: Sendable, Hashable {
        public let chunkID: String
        public let affectedMutationCount: Int
        public let diagnosticReference: String

        public init(chunkID: String, affectedMutationCount: Int, diagnosticReference: String) {
            self.chunkID = chunkID
            self.affectedMutationCount = affectedMutationCount
            self.diagnosticReference = diagnosticReference
        }
    }

    /// One shared-chunk-level infrastructure condition (currently: the
    /// chunk's own build succeeded, but the compilation-unit-to-built-image
    /// receipt could not be resolved for it) that sent every `MutationID`
    /// it covers to isolated fallback — the same "one aggregate event per
    /// occurrence, never one per affected `MutationID`" shape
    /// `SharedChunkBuildFailureEvent` already uses, kept as a distinct type
    /// (not folded into that one) because the *meaning* is different: this
    /// is not a compile failure at all, the chunk built and is otherwise
    /// usable, only its receipt could not be established. `reason` is
    /// carried explicitly (rather than being implied by which event type
    /// this is, the way `SharedChunkBuildFailureEvent` implies "compile
    /// failure") so this type can grow further infrastructure-only fallback
    /// causes later without becoming a second flavor of `SharedChunkBuildFailureEvent`.
    public struct SchemataInfrastructureFallbackEvent: Sendable, Hashable {
        public let chunkID: String
        public let reason: SchemataFallbackReason
        public let affectedMutationCount: Int
        public let diagnosis: String

        public init(chunkID: String, reason: SchemataFallbackReason, affectedMutationCount: Int, diagnosis: String) {
            self.chunkID = chunkID
            self.reason = reason
            self.affectedMutationCount = affectedMutationCount
            self.diagnosis = diagnosis
        }
    }

    /// Why a mutation could not be scored from schemata evidence, kept as
    /// structurally distinct cases rather than one flat enumeration
    /// (ADR-0008): `.activation` wraps `MutationVerdictVerifier
    /// .SchemataIsolatedFallbackReason` verbatim — the verifier remains the
    /// sole authority on *what that reason means*, this type only tags
    /// *where* the reason came from. `.hangBudgetExceeded` and
    /// `.sharedChunkBuildFailure` are never verdicts at all — both are this
    /// runner's own scheduling decisions, made without consulting, and
    /// without weakening, any verifier classification: `.hangBudgetExceeded`
    /// (ADR-0008 §3.3) that a `MutationID` could not be safely finished
    /// under schemata within one chunk's hang budget;
    /// `.sharedChunkBuildFailure` (ADR-0008 Addendum 4) that a typed
    /// `BuildFailure` from the chunk's own shared build is chunk-level
    /// evidence only, never per-mutant compile evidence, so it cannot by
    /// itself establish any individual `MutationID`'s verdict — only a
    /// subsequent isolated-mode build/test may.
    public enum SchemataFallbackReason: Sendable, Hashable {
        case activation(MutationVerdictVerifier.SchemataIsolatedFallbackReason)
        case hangBudgetExceeded
        case sharedChunkBuildFailure
        /// The shared baseline's own aggregate coverage map already proves
        /// this line was never executed (`CoverageMap.isKnownUncovered`) —
        /// routed to isolated mode *before* any token was ever attempted,
        /// never after. Isolated mode's own `MutationRunner.prepare(...)`
        /// takes the identical fast path for the identical reason —
        /// confirmed empirically: without it, a full token attempt would be
        /// spent on a mutation this same shared coverage data already knew
        /// was unreachable.
        case knownUncovered
        /// The chunk's own shared build succeeded, but the compilation-
        /// unit-to-built-image receipt required to prove which built image
        /// this chunk's mutations actually reached could not be resolved
        /// (`SchemataBuildable.resolveSchemataBuildReceipt` threw, or
        /// resolved ambiguously). Never scored as if the receipt were
        /// simply absent (`receipt: nil` silently proceeding) — a build
        /// whose own image identity cannot be proven is schemata-unusable
        /// for every `MutationID` it covers, the same all-or-nothing
        /// discipline `.sharedChunkBuildFailure` already applies to a
        /// genuine compile failure, applied here to a different
        /// infrastructure failure with the identical consequence.
        case buildReceiptUnavailable
    }

    /// One mutation this run could not prove activation for from schemata
    /// evidence alone, and therefore never scored — see `Outcome
    /// .isolatedFallbacks`'s own doc comment.
    public struct DynamicFallback: Sendable, Hashable {
        public let mutationID: MutationID
        public let reason: SchemataFallbackReason

        public init(mutationID: MutationID, reason: SchemataFallbackReason) {
            self.mutationID = mutationID
            self.reason = reason
        }
    }

    public enum RunError: Error, CustomStringConvertible {
        /// `record` is the failed baseline itself, carried rather than left
        /// to be re-synthesized by whoever catches this: everything a reader
        /// needs to tell a build failure from a suite that ran and failed
        /// (the commands, the durations, the test summary) lives on it, and
        /// a caller that only has `diagnosis` has no way to put any of it
        /// back. `SchemataRunOrchestration.merge` attaches exactly this
        /// record to the degraded report, which is what that function's own
        /// doc comment already promises a reader will see.
        case baselineDidNotPass(record: BaselineRecord, diagnosis: String)

        public var description: String {
            switch self {
            case let .baselineDidNotPass(_, diagnosis):
                "the schemata baseline did not pass, so no mutant can be scored against it: \(diagnosis)"
            }
        }
    }

    private let planID: String
    /// A real per-shard identity — see `MutationRunner`'s own equivalent
    /// fix (ADR-0006 Stage 1): `planID` alone cannot distinguish two
    /// shards of the same plan.
    private let workUnitID: String
    private let programs: [SchemataProgram]
    private let points: [MutationID: MutationPoint]
    /// Pristine, pre-lowering file content keyed by `MutationPoint.file` —
    /// the same `sources` map `SchemataChunkPlanner.plan(...)` was given.
    /// Needed to compute honest, non-fabricated source-level evidence
    /// (`MutationEvidence.sourceDiff` and friends) for each embedded
    /// mutation, since `SchemataProgram.loweredSources` only carries the
    /// final, already-rewritten chunk content.
    private let originalSources: [String: Data]
    private let build: any SchemataBuildable
    private let test: any SchemataTestable
    private let workspaces: WorkspaceManager
    /// The whole `TimeoutSettings` block, not a single pre-resolved number
    /// — because schemata mode needs *two* structurally different limits and
    /// an earlier single-`timeoutSeconds` parameter silently collapsed them
    /// into one. `establishBaseline` runs the full, unmutated suite once and
    /// is bounded by `baselineLimitSeconds`; every per-entry
    /// `runSchemataToken` spawn runs one mutant and must be bounded by the
    /// same per-mutant limit isolated mode uses (`TimeoutController
    /// .mutantLimitSeconds`, resolved adaptively against this run's own
    /// measured baseline duration — see `run()`).
    ///
    /// Measured cost of the collapsed version, on a real 602-mutant corpus
    /// (`swift-async-algorithms`, 2026-08): every schemata mutant was given
    /// the 600 s *baseline* limit instead of the configured 186 s per-mutant
    /// one, and the 19 mutants that actually hit it burned 5.99 h of the
    /// 6.58 h total schemata wall time — ~4 h of a 21 h run. Isolated mode
    /// was correct throughout; only this backend was over-budgeted.
    private let timeouts: TimeoutSettings
    /// The real toolchain/build-argument identity this run's plan was
    /// validated against (`ExecutableSchemataPlan.toolchainHash`/
    /// `buildArgumentsHash`) — hashed once into the `SHA256Digest` shape
    /// `SchemataBuildReceipt` requires. A genuine content hash of the
    /// plan's own already-validated identity strings, not a placeholder.
    private let toolchainHash: SHA256Digest
    private let buildArgumentsHash: SHA256Digest
    /// The same `VerdictVerificationPolicy` an isolated `MutationRunner`
    /// would be constructed with for this run — the one source of truth
    /// both backends ask `MutationVerdictVerifier.confirmationRequirement`
    /// against, so schemata mode gathers exactly the confirmations
    /// `retestKilledMutants`/`confirmCrashKills`/`confirmTimedOutMutants`
    /// promise, never a policy this runner invents on its own.
    private let policy: MutationVerdictVerifier.VerdictVerificationPolicy
    /// `configuration.execution.selectCoveringTests`, mirrored the same way
    /// `MutationRunner` reads it: covering-test selection is opt-in, and
    /// `false` (the config schema's own default) must reproduce this
    /// runner's exact pre-existing behaviour — every embedded mutation's
    /// token run against the full configured test list, unrestricted.
    private let selectCoveringTests: Bool
    /// ADR-0008 §3.3's per-chunk hang budget: how many verifier-confirmed
    /// `.verifiedTimeout` entries one chunk may accumulate before its
    /// remaining not-yet-fully-finalized `MutationID`s are dropped from
    /// schemata scoring and routed to isolated-mode fallback instead (see
    /// `runEntries`). **Count-based, not wall-clock, and deliberately not a
    /// tuned production value** — the ADR itself leaves the exact budget
    /// composition open pending real-corpus data (§"Not Yet Decided"); this
    /// default exists only so every pre-ADR-0008 call site keeps compiling,
    /// not as a considered choice. A future milestone's real-corpus
    /// validation should set the production default deliberately, not
    /// inherit this placeholder.
    private let maxVerifiedTimeoutsPerChunk: Int
    /// How many `programs` chunks may run concurrently — the same
    /// `Configuration.execution.resolvedWorkerCount()` convention isolated
    /// mode's own `MutationRunner.evaluate` already resolves and bounds its
    /// worker pool by (`half the core count` when unset), mirrored here
    /// rather than reinvented. Defaults to `1`: every pre-existing call site
    /// that constructs a `SchemataMutationRunner` without this parameter
    /// keeps today's fully-sequential behaviour, unchanged.
    private let workers: Int
    /// The same cross-run per-test coverage cache isolated mode's own
    /// `MutationRunner` already consults, reused verbatim rather than
    /// reinvented for this backend: the attribution pass it skips is the
    /// single most expensive thing either backend's baseline does, and it
    /// depends on the source tree/tests/toolchain — not on which backend or
    /// which mutants are running — so both backends are entitled to the same
    /// entry under the same key. `nil` (the default) means "not configured",
    /// which reproduces this runner's exact pre-cache behaviour: measure on
    /// every run, consult nothing, store nothing.
    private let coverageCache: CoverageProfileCache?
    /// The digest identifying *which* measured attribution a cache entry is
    /// (`RunContextProbe.computeContextDigest`, computed in the CLI layer).
    /// `nil` means the CLI could not compute one — a best-effort degradation,
    /// never a failed run — and, exactly as in `MutationRunner`, that means
    /// coverage is measured fresh and nothing is stored.
    private let coverageCacheKey: CoverageProfileCache.Key?
    /// When supplied, `establishBaseline()` uses this instead of building
    /// and testing the project itself — see `SharedBaselineEstablisher`'s
    /// own doc comment. `nil` for every existing caller (a plain schemata
    /// run with no isolated-fallback portion), which is unaffected by this
    /// parameter's existence.
    private let preEstablishedBaseline: SharedBaselineEstablisher.Outcome?
    /// The most primary token attempts `runEntries` will fold into one
    /// shared `runSchemataTokenBatch` call, mirroring isolated mode's own
    /// `execution.testBatchSize` (the identical setting `testOneBatch`/
    /// `testWaveChunk` already use) rather than inventing a separate
    /// schemata-specific knob. Defaults to `1`: every pre-existing call
    /// site that constructs a `SchemataMutationRunner` without this
    /// parameter keeps today's fully-unbatched, one-fresh-process-per-token
    /// behaviour, unchanged — the same opt-in-by-default-value convention
    /// `workers` already uses above. `<= 1` disables batching outright
    /// (see `prepareBatchedPrimaries`): a "batch" of one token has no
    /// containment benefit over the unbatched path.
    private let schemataTokenBatchSize: Int
    /// Counts *chunks*, not mutants: a chunk is this backend's unit of
    /// build-and-test work, so it is what a human watching the run is
    /// actually waiting on. The isolated backend counts mutants for the same
    /// reason — there, one mutant is one build-and-test cycle.
    private let progress: MutationProgressReporter?

    public init(
        planID: String,
        workUnitID: String,
        programs: [SchemataProgram],
        points: [MutationID: MutationPoint],
        originalSources: [String: Data],
        build: any SchemataBuildable,
        test: any SchemataTestable,
        workspaces: WorkspaceManager,
        timeouts: TimeoutSettings,
        toolchainHash: String,
        buildArgumentsHash: String,
        policy: MutationVerdictVerifier.VerdictVerificationPolicy,
        maxVerifiedTimeoutsPerChunk: Int = 3,
        selectCoveringTests: Bool = false,
        workers: Int = 1,
        coverageCache: CoverageProfileCache? = nil,
        coverageCacheKey: CoverageProfileCache.Key? = nil,
        preEstablishedBaseline: SharedBaselineEstablisher.Outcome? = nil,
        schemataTokenBatchSize: Int = 1,
        progress: MutationProgressReporter? = nil
    ) {
        self.planID = planID
        self.workUnitID = workUnitID
        self.programs = programs
        self.points = points
        self.originalSources = originalSources
        self.build = build
        self.test = test
        self.workspaces = workspaces
        self.timeouts = timeouts
        self.toolchainHash = SHA256Digest.of(Data(toolchainHash.utf8))
        self.buildArgumentsHash = SHA256Digest.of(Data(buildArgumentsHash.utf8))
        self.policy = policy
        self.maxVerifiedTimeoutsPerChunk = maxVerifiedTimeoutsPerChunk
        self.selectCoveringTests = selectCoveringTests
        self.workers = workers
        self.coverageCache = coverageCache
        self.coverageCacheKey = coverageCacheKey
        self.preEstablishedBaseline = preEstablishedBaseline
        self.schemataTokenBatchSize = schemataTokenBatchSize
        self.progress = progress
    }

    public func run() async throws -> Outcome {
        let established = try await establishBaseline()
        let baseline = established.record
        let perTestCoverage = established.perTestCoverage
        let coverage = established.coverage
        // Both paths in `establishBaseline` already throw on a baseline that
        // did not pass, each with its own observed diagnosis. What is left
        // here is the one case neither covers: a caller-supplied
        // `.established(_)` whose `record` nevertheless says it failed —
        // `SharedBaselineEstablisher` never produces one, but the type
        // permits it, and proceeding would score mutants against a suite
        // that was never green. Only here is a sentence reconstructed from
        // the counts, because here there is no observation left to quote.
        guard baseline.passed else {
            let summary = baseline.testSummary.map { "\($0.failed) of \($0.total) tests failed" }
            throw RunError.baselineDidNotPass(
                record: baseline, diagnosis: summary ?? "the baseline test run did not pass"
            )
        }

        // ADR-0008 §4(b): a `MutationID` embedded into more than one target
        // lands in a *different* `SchemataProgram`/chunk per target
        // (`SchemataChunkPlanner.classify`), so "is this MutationID fully
        // finalized" can never be answered from inside one chunk alone.
        // `expectedPlacementsByMutationID` is computed once, up front, from
        // every program's own entries; `completedPlacementsByMutationID` is
        // folded in only *after* each chunk fully returns (never mid-chunk),
        // so what a still-running chunk's own overflow check consults is
        // always "every *other* chunk's contribution so far" — its own
        // chunk's contribution is accounted for separately, inline, by
        // `runEntries` itself (see that function's overflow-closure comment).
        //
        // Now that chunks run concurrently (`workers` > 1), this is the one
        // piece of cross-chunk state that cannot stay a plain snapshot: two
        // concurrently-running chunks that both embed the same `MutationID`
        // may each hit their own hang-budget overflow around the same time,
        // and each must see the other's up-to-date-as-of-now contribution,
        // not one frozen at whichever moment they happened to start. Wrapped
        // in `CompletedPlacementsTracker` (an actor) for that reason — and,
        // just as importantly, the *read* point was moved, not only the
        // storage: a chunk that snapshotted once at its own start could sit
        // on a stale value for its entire (possibly long) run, missing a
        // concurrently-running sibling's fold-in that lands anywhere after
        // that start. `runEntries` instead reads the tracker fresh at the
        // one moment that actually matters — right where its own
        // hang-budget overflow fires, immediately before
        // `hangBudgetOverflowClosure` is called — so the value consulted is
        // always as current as the tracker allows, however long this
        // chunk's own run took to get there. The fold-in write is
        // unchanged: once per chunk, made only after that chunk fully
        // returns. `hangBudgetOverflowClosure` itself stays fully
        // synchronous, consulting a plain `[MutationID: Int]` handed to it
        // fresh by its caller, unaware this is backed by an actor.
        let expectedPlacementsByMutationID = Self.expectedPlacementCounts(programs: programs)
        let completedPlacements = CompletedPlacementsTracker()

        // The per-mutant limit, resolved exactly the way isolated mode
        // resolves its own (`MutationRunner.establishBaseline` ->
        // `TimeoutController.recordingBaseline`): adaptively, from the
        // measured duration of *this* run's own baseline test execution,
        // falling back to the configured ceiling when the baseline reported
        // no test duration at all. Never the baseline's own limit — a
        // baseline runs the whole unmutated suite once, one token run runs
        // one mutant, and conflating the two is what made a hanging schemata
        // mutant cost 600 s where isolated mode spent 186 s (see `timeouts`).
        //
        // The controller itself — not a single pre-resolved `Double` — is
        // threaded down to every chunk/entry from here on: each embedded
        // entry has its own `selectedTests` (resolved in `runPrimary`, the
        // same call site isolated mode's own `prepare` resolves it at), and
        // `TimeoutController.mutantLimitSeconds(selectedTests:)` needs the
        // live controller so an entry without a usable selection still falls
        // back to this whole-suite-scaled value, while an entry with a
        // known, non-empty selection gets the small, fixed 10...30s clamp
        // instead — see that method's own doc comment.

        let timeoutController = TimeoutController(settings: timeouts)
        let resolvedTimeoutController = baseline.testDurationSeconds
            .map { timeoutController.recordingBaseline(durationSeconds: $0) }
            ?? timeoutController

        // Bounded fan-out (mirrors `MutationRunner.evaluate`'s own "one in,
        // one out" `TaskGroup` pattern): at most `workers` chunks in flight
        // at once. `workers: 1` launches the next chunk only once
        // `group.next()` yields the previous one's result, which is exactly
        // today's sequential order — same chunk-start snapshot point, same
        // fold-in point, same `entryOutcomes`/`buildFailureEvents`
        // accumulation order as the old `for program in programs` loop.
        var entryOutcomes: [EntryRunOutcome] = []
        var buildFailureEvents: [SharedChunkBuildFailureEvent] = []
        var infrastructureFallbackEvents: [SchemataInfrastructureFallbackEvent] = []
        let workerCount = max(1, workers)

        await withTaskGroup(of: ChunkTaskOutcome.self) { group in
            var remainingPrograms = programs.makeIterator()

            for _ in 0 ..< workerCount {
                guard let program = remainingPrograms.next() else { break }
                group.addTask {
                    await self.runChunkTracked(
                        program, timeoutController: resolvedTimeoutController, perTestCoverage: perTestCoverage, coverage: coverage,
                        expectedPlacementsByMutationID: expectedPlacementsByMutationID, tracker: completedPlacements
                    )
                }
            }

            while let result = await group.next() {
                entryOutcomes.append(contentsOf: result.outcomes)
                buildFailureEvents.append(contentsOf: result.buildFailureEvents)
                infrastructureFallbackEvents.append(contentsOf: result.infrastructureFallbackEvents)
                await progress?.recordCompletion()
                if let program = remainingPrograms.next() {
                    group.addTask {
                        await self.runChunkTracked(
                            program, timeoutController: resolvedTimeoutController, perTestCoverage: perTestCoverage, coverage: coverage,
                            expectedPlacementsByMutationID: expectedPlacementsByMutationID, tracker: completedPlacements
                        )
                    }
                }
            }
        }

        // All-or-nothing per MutationID (never per placement): if *any* of
        // a mutation's target placements lacked runtime activation proof,
        // every placement's own schemata `TargetRecord` for that
        // `MutationID` — including one that individually verified fine —
        // is dropped before grouping. Never merge a schemata result for
        // one target with an isolated-fallback result for another; that
        // would double-ledger the same MutationID across two backends.
        var dynamicFallbackReasons: [MutationID: SchemataFallbackReason] = [:]
        for case let .isolatedFallback(mutationID, reason) in entryOutcomes {
            dynamicFallbackReasons[mutationID] = reason
        }
        let perTarget: [TargetRecord] = entryOutcomes.compactMap {
            guard case let .verified(record) = $0, dynamicFallbackReasons[record.record.mutationRef.mutationID] == nil else { return nil }
            return record
        }

        // Sorted by `MutationID`, not `entryOutcomes`'s own accumulation
        // order: with chunks now running concurrently, that accumulation
        // order follows completion order, not `programs` order, so it is no
        // longer deterministic run-to-run. `groupByMutation`'s own
        // first-appearance-in-`perTarget` order would otherwise leak that
        // nondeterminism into `results`/`multiTargetVerdicts` — sorted here
        // for the same reason `isolatedFallbacks` below already is.
        let grouped = try Self.groupByMutation(perTarget)
            .sorted { $0.verdict.mutationRef.mutationID.rawValue < $1.verdict.mutationRef.mutationID.rawValue }
        let verdicts = grouped.map { $0.verdict }
        let results = try grouped.map {
            try Self.projectAggregate($0, points: points, planID: planID, workUnitID: workUnitID)
        }
        // Deterministic order (sorted, not orchestration/completion order),
        // the same discipline `SchemataChunkPlanner`'s own chunk IDs use.
        let isolatedFallbacks = dynamicFallbackReasons
            .map { DynamicFallback(mutationID: $0.key, reason: $0.value) }
            .sorted { $0.mutationID.rawValue < $1.mutationID.rawValue }
        return Outcome(
            baseline: baseline, results: results, multiTargetVerdicts: verdicts, isolatedFallbacks: isolatedFallbacks,
            sharedChunkBuildFailureEvents: buildFailureEvents,
            infrastructureFallbackEvents: infrastructureFallbackEvents
        )
    }

    /// What one embedded entry's own attempt produced — either a fully
    /// verified schemata result, or a signal that this `MutationID` (every
    /// target placement, not just this one) needs to be re-run through
    /// isolated mode instead (see `Outcome.isolatedFallbacks`'s own doc
    /// comment).
    private enum EntryRunOutcome {
        case verified(TargetRecord)
        case isolatedFallback(mutationID: MutationID, reason: SchemataFallbackReason)

        var mutationID: MutationID {
            switch self {
            case let .verified(record): record.record.mutationRef.mutationID
            case let .isolatedFallback(mutationID, _): mutationID
            }
        }
    }

    /// Concurrency-safe home for `completedPlacementsByMutationID`
    /// (ADR-0008 §4(b) — see `run()`'s own doc comment above where this is
    /// constructed for the full rationale). An `actor` rather than a plain
    /// `var` because `run()` now fans chunks out over a bounded
    /// `TaskGroup`: two chunks that both embed the same `MutationID` may run
    /// concurrently and each need an accurate, up-to-date-as-of-now count of
    /// the other's contribution when their own hang-budget-overflow check
    /// fires, not a snapshot frozen at whichever moment they started.
    private actor CompletedPlacementsTracker {
        private var counts: [MutationID: Int] = [:]

        /// Read fresh at the exact moment a chunk's own hang-budget overflow
        /// fires (`runEntries`, right where `hangBudgetOverflowClosure` is
        /// called) — never once, frozen, at chunk start. A chunk-start
        /// snapshot goes stale the instant a concurrently-running sibling
        /// chunk folds its own contribution in later, mid-run: two chunks
        /// embedding the same `MutationID` can each be mid-flight when the
        /// other finishes, and by the time *this* chunk's own overflow
        /// actually fires — however much later that is — it must see
        /// whatever every other chunk has folded in as of *now*, not as of
        /// whenever this chunk happened to start.
        func snapshot() -> [MutationID: Int] { counts }

        /// Folded in once per chunk, only after that chunk fully returns —
        /// same fold-in point, same "once per `MutationID`, not once per
        /// outcome" dedup discipline the old loop used (see `runChunkTracked`).
        func fold(in mutationIDs: some Sequence<MutationID>) {
            for mutationID in mutationIDs {
                counts[mutationID, default: 0] += 1
            }
        }
    }

    /// One chunk task's contribution to the `TaskGroup` in `run()` — the
    /// same two fields `ChunkRunResult` already carries, just `Sendable` and
    /// named for its role as a task-group element rather than as
    /// `runChunk`'s own return value (kept distinct from `ChunkRunResult`
    /// itself only because renaming that type's own long-established call
    /// sites is out of scope here).
    private struct ChunkTaskOutcome: Sendable {
        let outcomes: [EntryRunOutcome]
        let buildFailureEvents: [SharedChunkBuildFailureEvent]
        let infrastructureFallbackEvents: [SchemataInfrastructureFallbackEvent]
    }

    /// One task-group child's whole lifecycle: run the chunk with a live
    /// reference to the tracker (never a value snapshotted up front — see
    /// `CompletedPlacementsTracker.snapshot()`'s own doc comment for why),
    /// fold this chunk's own contribution back into the tracker once it
    /// fully returns, return. Never called for more than one chunk
    /// concurrently from the same `Task` — `run()`'s `TaskGroup` is what
    /// bounds how many of these run at once (`workers`).
    private func runChunkTracked(
        _ program: SchemataProgram, timeoutController: TimeoutController, perTestCoverage: PerTestCoverageMap?,
        coverage: CoverageMap?, expectedPlacementsByMutationID: [MutationID: Int], tracker: CompletedPlacementsTracker
    ) async -> ChunkTaskOutcome {
        let chunkResult = await runChunk(
            program, timeoutController: timeoutController, perTestCoverage: perTestCoverage, coverage: coverage,
            expectedPlacementsByMutationID: expectedPlacementsByMutationID,
            tracker: tracker
        )
        // Deduped by `MutationID`, not one increment per outcome: a chunk
        // whose own hang-budget overflow retroactively flags an earlier,
        // already-`.verified` entry in the *same* chunk (§4(b)) returns two
        // outcomes for that one `MutationID` (its verified record and the
        // overflow's `.isolatedFallback`) — both belong to the same single
        // placement this chunk contributed, so it must count once here, not
        // twice, or a later chunk's own finalization check would see an
        // inflated count.
        //
        // Deliberately not covered by an end-to-end `Outcome`-level test
        // (raised in review, disposed here rather than contrived): any
        // `MutationID` that ever earns a `.isolatedFallback` entry in one
        // chunk is *permanently* excluded from `results`/`multiTargetVerdicts`
        // by the dict-based scan in `run()`, for every chunk for the rest of
        // this run — count inflation for that same `MutationID` can only
        // ever make a later chunk's "already fully finalized" check pass
        // *more* easily, never less, and an already-excluded `MutationID`
        // staying excluded either way is not an observable difference in
        // `Outcome`. This dedup is correct-by-construction hygiene for the
        // internal invariant ("this dict counts placements, not outcomes"),
        // not something the current single consumer can be made to expose a
        // passing-vs-failing test for.
        await tracker.fold(in: Set(chunkResult.outcomes.map(\.mutationID)))
        return ChunkTaskOutcome(
            outcomes: chunkResult.outcomes, buildFailureEvents: chunkResult.buildFailureEvents,
            infrastructureFallbackEvents: chunkResult.infrastructureFallbackEvents
        )
    }

    /// How many of `programs`' own (embedded) entries exist for each
    /// `MutationID` — a mutation embedded into N targets appears in N
    /// different programs (`SchemataChunkPlanner.classify`), each
    /// contributing exactly one entry, so this is also "how many target
    /// placements must all finalize before this `MutationID` counts as
    /// done" (ADR-0008 §4(b)).
    private static func expectedPlacementCounts(programs: [SchemataProgram]) -> [MutationID: Int] {
        var counts: [MutationID: Int] = [:]
        for program in programs {
            for entry in program.entries where entry.isEmbedded {
                counts[entry.mutationID, default: 0] += 1
            }
        }
        return counts
    }

    /// One target's own verified record, paired with which target
    /// produced it — the raw material `groupIntoMultiTargetVerdicts` folds
    /// into one `MultiTargetVerdict` per mutation.
    private struct TargetRecord {
        let targetIdentity: TargetExecutionIdentity
        let record: VerifiedMutationRecord
        let durationSeconds: Double
        let testDurationSeconds: Double?
    }

    /// One mutation's `MultiTargetVerdict`, paired with the raw
    /// `TargetRecord`s it was built from — kept alongside so
    /// `projectAggregate` can recover the winning target's own timing,
    /// which `TargetVerdict` itself does not carry.
    private struct GroupedMutation {
        let verdict: MultiTargetVerdict
        let perTarget: [TargetRecord]
    }

    /// A mutation embedded into more than one target (see
    /// `SchemataChunkPlanner.classify`) runs — and is verified — once per
    /// target, independently, since each is a genuinely separate build.
    /// Groups every target's own record by `MutationID` into one
    /// `MultiTargetVerdict`, preserving every target's evidence — see
    /// `MultiTargetVerdict`'s own doc comment for why this replaced
    /// ADR-0005 PR F's lossy `mergeMultiTargetResults`.
    private static func groupByMutation(_ perTarget: [TargetRecord]) throws -> [GroupedMutation] {
        var order: [MutationID] = []
        var grouped: [MutationID: [TargetRecord]] = [:]
        for entry in perTarget {
            let id = entry.record.mutationRef.mutationID
            if grouped[id] == nil { order.append(id) }
            grouped[id, default: []].append(entry)
        }
        return try order.map { id in
            let records = grouped[id]!
            let verdict = try MultiTargetVerdict(
                mutationRef: records[0].record.mutationRef,
                perTarget: records.map { TargetVerdict(targetIdentity: $0.targetIdentity, record: $0.record) }
            )
            return GroupedMutation(verdict: verdict, perTarget: records)
        }
    }

    /// Projects a mutation's aggregate outcome into a single
    /// `MutationResult` for display — the specific `TargetRecord` whose
    /// own outcome equals `aggregateOutcome` (ties broken by `perTarget`'s
    /// own deterministic, identity-sorted order), never a value computed
    /// independently of it.
    private static func projectAggregate(
        _ grouped: GroupedMutation, points: [MutationID: MutationPoint], planID: String, workUnitID: String
    ) throws -> MutationResult {
        let verdict = grouped.verdict
        // Ties broken by target identity, not by whichever chunk happened
        // to finish evaluating first: `grouped.perTarget` is orchestration
        // order (per-chunk completion), not the deterministic order
        // `verdict.perTarget` already sorts into.
        let winningIdentities = verdict.perTarget
            .filter { $0.record.outcome == verdict.aggregateOutcome }
            .map(\.targetIdentity)
        let winnerIdentity = winningIdentities.min() ?? verdict.perTarget[0].targetIdentity
        let winner = grouped.perTarget.first { $0.targetIdentity == winnerIdentity } ?? grouped.perTarget[0]
        guard let point = points[verdict.mutationRef.mutationID] else {
            preconditionFailure("no MutationPoint supplied for embedded mutation \(verdict.mutationRef.mutationID.rawValue)")
        }
        return try MutationResult.projected(
            from: winner.record, point: point, planID: planID, workUnitID: workUnitID,
            durationSeconds: winner.durationSeconds, testDurationSeconds: winner.testDurationSeconds
        )
    }

    // MARK: - Baseline

    /// `establishBaseline`'s full result: the record every caller already
    /// expected, plus — when `execution.selectCoveringTests` asked for it
    /// and the adapter could produce one — the per-test attribution
    /// `run()` threads down to every embedded mutation's own token run.
    /// `perTestCoverage == nil` means every mutant runs the full configured
    /// test list, the same safe fallback isolated mode's own
    /// `MutationRunner.BaselineContext` uses.
    private struct BaselineEstablishment {
        let record: BaselineRecord
        let perTestCoverage: PerTestCoverageMap?
        /// The aggregate "was this line ever executed at all" map — distinct
        /// from `perTestCoverage`'s "which tests cover it" attribution, the
        /// same distinction `MutationRunner.BaselineContext` draws. Used
        /// only for the `coverage.isKnownUncovered(point)` pre-check (see
        /// `runPrimary`) that lets a mutation on a genuinely-unreached line
        /// skip a schemata token attempt entirely, the same fast path
        /// isolated mode's own `prepare(...)` already takes.
        let coverage: CoverageMap?
    }

    /// Throws `RunError.baselineDidNotPass` rather than returning a failed
    /// record, so the diagnosis is thrown by whoever actually observed the
    /// failure and no caller has to reconstruct one. The alternative this
    /// replaces — returning the record and letting `run()` re-derive a
    /// sentence from `testSummary` — could only ever say "N of M tests
    /// failed", and on the failure shape that actually occurred in CI (a
    /// baseline whose suite ran nothing: `0 of 0`) that names neither what
    /// failed nor that nothing ran at all.
    private func establishBaseline() async throws -> BaselineEstablishment {
        if let preEstablishedBaseline {
            switch preEstablishedBaseline {
            case let .failed(record, diagnosis):
                throw RunError.baselineDidNotPass(record: record, diagnosis: diagnosis)
            case let .established(shared):
                return BaselineEstablishment(record: shared.record, perTestCoverage: shared.perTestCoverage, coverage: shared.coverage)
            }
        }

        let started = Date()
        let spanStart = GateTimingRecorder.shared.now()
        let sandbox = try await workspaces.createSandbox(id: "schemata-baseline")
        do {
            let established = try await establishBaseline(in: sandbox, startedAt: started)
            try? await workspaces.destroySandbox(at: sandbox)
            await GateTimingRecorder.shared.record("schemata.baseline.total", start: spanStart)
            return established
        } catch {
            try? await workspaces.destroySandbox(at: sandbox)
            await GateTimingRecorder.shared.record("schemata.baseline.total.failed", start: spanStart)
            throw error
        }
    }

    private func establishBaseline(in sandbox: URL, startedAt started: Date) async throws -> BaselineEstablishment {
        let baselineBuildSpanStart = GateTimingRecorder.shared.now()
        let artifact = try await build.buildBaseline(in: sandbox)
        await GateTimingRecorder.shared.record("schemata.baseline.build", start: baselineBuildSpanStart)
        let testStarted = Date()
        let baselineTestSpanStart = GateTimingRecorder.shared.now()
        // The baseline's own limit, unchanged: this run compiles nothing
        // mutated and executes the entire suite once, which is a different
        // — legitimately longer — concern from one mutant's own run.
        let run = try await test.runBaseline(
            artifact, in: sandbox, timeoutSeconds: TimeoutController(settings: timeouts).baselineLimitSeconds
        )
        await GateTimingRecorder.shared.record("schemata.baseline.test", start: baselineTestSpanStart)
        let testDurationSeconds = Date().timeIntervalSince(testStarted)

        let record = BaselineRecord(
            passed: run.status == .passed,
            testSummary: run.summary,
            durationSeconds: Date().timeIntervalSince(started),
            buildProductHash: artifact.productHash,
            buildCommand: artifact.command,
            testCommand: run.command,
            buildDurationSeconds: testStarted.timeIntervalSince(started),
            testDurationSeconds: testDurationSeconds
        )

        // Thrown here, where `run` — the observation itself — is still in
        // hand: `SharedBaselineEstablisher` words the identical failure the
        // identical way, and neither wording is re-derived from the record's
        // counts afterwards.
        guard record.passed else {
            throw RunError.baselineDidNotPass(record: record, diagnosis: SharedBaselineEstablisher.suiteDidNotPassDiagnosis(run))
        }

        // Per-test attribution (`execution.selectCoveringTests`), measured
        // — like isolated mode's own `MutationRunner.establishBaseline` —
        // *before* the sandbox above is destroyed by the caller: the
        // per-test coverage read needs the same instrumented artifact/
        // sandbox `runBaseline` just used. Only reached once the baseline is
        // known to have passed (the guard above already threw otherwise, and
        // there is nothing legitimate to attribute against a suite that did
        // not pass), only when configured, and only when the adapter conforms to
        // `TestSelecting` — mirroring `MutationRunner`'s exact guard
        // structure so a coverage-blind schemata adapter (no `TestSelecting`
        // conformance) behaves identically to before this parameter existed.
        //
        // The `CoverageProfileCache` is consulted *before* the adapter is
        // asked to measure anything, identically to `MutationRunner
        // .establishBaseline`: a hit skips the profiling pass entirely, a
        // miss measures as usual and stores the result back for the next
        // run. Only the coverage attribution is served from the cache — the
        // baseline build and suite run above have already happened either
        // way, because the suite-must-pass gate and the timeout calibration
        // are not facts a cache can stand in for.
        var perTestCoverage: PerTestCoverageMap?
        if selectCoveringTests {
            let coverageSpanStart = GateTimingRecorder.shared.now()
            if let key = coverageCacheKey, let cached = await coverageCache?.load(key) {
                perTestCoverage = cached
                await GateTimingRecorder.shared.record("schemata.coverage.cacheHit", start: coverageSpanStart)
            } else if let selecting = test as? any TestSelecting {
                perTestCoverage = await selecting.measurePerTestCoverage(
                    artifact: artifact, in: sandbox, timeoutSeconds: TimeoutController(settings: timeouts).baselineLimitSeconds
                )
                if let measured = perTestCoverage, let key = coverageCacheKey {
                    await coverageCache?.store(measured, for: key)
                }
                await GateTimingRecorder.shared.record("schemata.coverage.measured", start: coverageSpanStart)
            }
        }

        // Reported to stderr only: this runner has no `OperationalIssueLog`
        // of its own, and this path runs only when no baseline was
        // pre-established for it — the `SharedBaselineEstablisher` that
        // normally establishes a schemata run's baseline reports the same
        // fact into `RunReport.operationalIssues` itself.
        if let perTestCoverage { await PerTestCoverageAttribution.report(perTestCoverage, to: nil) }
        // `flatMap`, not `?.`: `aggregate()` is itself optional now, and
        // returns `nil` for a partial attribution precisely so the
        // `.noCoverage` fast path cannot be driven by one (see its own doc
        // comment). Flattening keeps "no map at all" and "a map that cannot
        // answer the uncovered question" as the one value every caller
        // already handles.
        return BaselineEstablishment(
            record: record, perTestCoverage: perTestCoverage, coverage: perTestCoverage.flatMap { $0.aggregate() }
        )
    }

    // MARK: - Per chunk

    /// One chunk's contribution to the whole run: its entries' own
    /// outcomes, plus any ADR-0008 Addendum 4 aggregate build-failure
    /// events it generated (at most one in practice — a chunk stops as
    /// soon as any build attempt, initial or recovery, fails — but kept as
    /// an array rather than an `Optional` so accumulation at every call
    /// site is uniform, never a special case).
    private struct ChunkRunResult {
        let outcomes: [EntryRunOutcome]
        let buildFailureEvents: [SharedChunkBuildFailureEvent]
        let infrastructureFallbackEvents: [SchemataInfrastructureFallbackEvent]

        static let empty = ChunkRunResult(outcomes: [], buildFailureEvents: [], infrastructureFallbackEvents: [])

        init(
            outcomes: [EntryRunOutcome], buildFailureEvents: [SharedChunkBuildFailureEvent],
            infrastructureFallbackEvents: [SchemataInfrastructureFallbackEvent]
        ) {
            self.outcomes = outcomes
            self.buildFailureEvents = buildFailureEvents
            self.infrastructureFallbackEvents = infrastructureFallbackEvents
        }

        /// Positional convenience for `runEntries`'s own several early-return
        /// sites, which repeatedly reconstruct this from the same three
        /// loop-local accumulators — the keyword form's three long labels
        /// made every one of those sites needlessly wide.
        init(
            _ outcomes: [EntryRunOutcome], _ buildFailureEvents: [SharedChunkBuildFailureEvent],
            _ infrastructureFallbackEvents: [SchemataInfrastructureFallbackEvent]
        ) {
            self.outcomes = outcomes
            self.buildFailureEvents = buildFailureEvents
            self.infrastructureFallbackEvents = infrastructureFallbackEvents
        }
    }

    private func runChunk(
        _ program: SchemataProgram,
        timeoutController: TimeoutController,
        perTestCoverage: PerTestCoverageMap?,
        coverage: CoverageMap?,
        expectedPlacementsByMutationID: [MutationID: Int],
        tracker: CompletedPlacementsTracker
    ) async -> ChunkRunResult {
        let embeddedEntries = program.entries.filter(\.isEmbedded)
        guard !embeddedEntries.isEmpty else { return .empty }

        let sandbox: URL
        do {
            let sandboxCreateStart = GateTimingRecorder.shared.now()
            sandbox = try await workspaces.createSandbox(id: program.chunkID)
            await GateTimingRecorder.shared.record("chunk.sandboxCreate", chunkID: program.chunkID, start: sandboxCreateStart)
        } catch {
            let outcomes = embeddedEntries.compactMap {
                infrastructureFailureResult(for: $0, reason: "the chunk sandbox could not be created: \(error)")
            }.map(EntryRunOutcome.verified)
            return ChunkRunResult(outcomes: outcomes, buildFailureEvents: [], infrastructureFallbackEvents: [])
        }

        let result = await runChunk(
            program, entries: embeddedEntries, in: sandbox, timeoutController: timeoutController,
            perTestCoverage: perTestCoverage, coverage: coverage,
            expectedPlacementsByMutationID: expectedPlacementsByMutationID,
            tracker: tracker
        )
        try? await workspaces.destroySandbox(at: sandbox)
        return result
    }

    private func runChunk(
        _ program: SchemataProgram, entries embeddedEntries: [SchemataPlanEntry], in sandbox: URL,
        timeoutController: TimeoutController,
        perTestCoverage: PerTestCoverageMap?,
        coverage: CoverageMap?,
        expectedPlacementsByMutationID: [MutationID: Int],
        tracker: CompletedPlacementsTracker
    ) async -> ChunkRunResult {
        switch await prepareChunkState(program: program, entries: embeddedEntries, in: sandbox) {
        case let .failed(outcomes, buildFailureEvent, infrastructureFallbackEvent):
            return ChunkRunResult(
                outcomes: outcomes, buildFailureEvents: buildFailureEvent.map { [$0] } ?? [],
                infrastructureFallbackEvents: infrastructureFallbackEvent.map { [$0] } ?? []
            )
        case let .ready(state):
            return await runEntries(
                embeddedEntries, program: program, state: state, timeoutController: timeoutController,
                perTestCoverage: perTestCoverage, coverage: coverage,
                expectedPlacementsByMutationID: expectedPlacementsByMutationID,
                tracker: tracker
            )
        }
    }

    /// Bundles one chunk's build product and receipt with the sandbox they
    /// were built in — the unit `prepareChunkState`/`rebuildChunkState`
    /// (ADR-0008) produce and every per-entry spawn consumes. Kept as a
    /// value, never mutated in place: a rebuild produces an entirely new
    /// `ChunkExecutionState`, it never patches an existing one.
    private struct ChunkExecutionState {
        let sandbox: URL
        let artifact: BuildArtifact
        let receipt: SchemataBuildReceipt?
    }

    /// `prepareChunkState`'s result: either a usable `ChunkExecutionState`,
    /// or the already-final `EntryRunOutcome`s every entry this attempt
    /// covered must be reported as (never both — this is the same
    /// exhaustive four-way split `runChunk`'s own initial build already
    /// used, kept exhaustive rather than becoming a throwing `Error` so a
    /// non-`Error` payload like `[EntryRunOutcome]` can be carried directly).
    private enum ChunkPreparationOutcome {
        case ready(ChunkExecutionState)
        /// `buildFailureEvent` is non-`nil` only for the typed-`BuildFailure`
        /// shape (ADR-0008 Addendum 4); `infrastructureFallbackEvent` is
        /// non-`nil` only for the build-receipt-unavailable shape. Mutually
        /// exclusive in practice (each failure path populates at most one),
        /// kept as two separate optionals rather than one combined enum so
        /// each aggregation site downstream can accumulate the two kinds
        /// into their own separate arrays without an extra unwrap.
        case failed(
            [EntryRunOutcome], buildFailureEvent: SharedChunkBuildFailureEvent? = nil,
            infrastructureFallbackEvent: SchemataInfrastructureFallbackEvent? = nil
        )
    }

    /// The single entry point for turning a sandbox into a built,
    /// receipt-resolved chunk — used both for a chunk's initial build and
    /// (ADR-0008) for every mid-chunk recovery rebuild after a forced
    /// timeout-kill, so both paths route through the exact same failure
    /// handlers by construction, never by separately-maintained duplicate
    /// logic: typed `BuildFailure` -> whole-`MutationID` dynamic isolated
    /// fallback (ADR-0008 Addendum 4 — a shared chunk build's `BuildFailure`
    /// is chunk-level evidence, not per-mutant compile evidence, so it must
    /// not directly establish `.unviable` for entries it merely happened to
    /// contain), untyped error / nil product hash -> `infrastructureFailure`
    /// (unchanged), receipt-resolution failure -> whole-chunk
    /// `.buildReceiptUnavailable` isolated fallback — no schemata execution
    /// ever proceeds without a proven receipt.
    private func prepareChunkState(
        program: SchemataProgram, entries embeddedEntries: [SchemataPlanEntry], in sandbox: URL
    ) async -> ChunkPreparationOutcome {
        let artifact: BuildArtifact
        do {
            artifact = try await build.buildSchemataChunk(loweredSources: program.loweredSources, in: sandbox)
        } catch let failure as BuildFailure {
            // Chunk-level evidence only (ADR-0008 Addendum 4): the shared
            // lowered program did not compile, which proves nothing about
            // any individual entry's own mutation. Every `MutationID` this
            // failed build/rebuild attempt covers falls back to isolated
            // mode as a whole — never per-placement — joining the same
            // all-or-nothing dynamic-fallback mechanism `run()` already
            // uses for activation/hang-budget fallback (see that function's
            // own `dynamicFallbackReasons` scan). Only a subsequent
            // isolated-mode build/test, verified by `MutationVerdictVerifier`
            // exactly as it is today, may establish `.unviable` for one of
            // these `MutationID`s. `failure` itself is preserved (not
            // discarded) so the fan-out/observability event below can
            // reference its own diagnosis — one aggregate event per failed
            // chunk build, never one per affected `MutationID`.
            return .failed(
                embeddedEntries.map { .isolatedFallback(mutationID: $0.mutationID, reason: .sharedChunkBuildFailure) },
                buildFailureEvent: SharedChunkBuildFailureEvent(
                    chunkID: program.chunkID, affectedMutationCount: embeddedEntries.count, diagnosticReference: failure.diagnosis
                )
            )
        } catch {
            return .failed(embeddedEntries.compactMap {
                infrastructureFailureResult(for: $0, reason: "the chunk build could not be run: \(error)")
            }.map(EntryRunOutcome.verified))
        }

        guard artifact.productHash != nil else {
            return .failed(embeddedEntries.compactMap {
                infrastructureFailureResult(
                    for: $0, reason: "the chunk build produced no product hash, so its evidence cannot be trusted"
                )
            }.map(EntryRunOutcome.verified))
        }

        // Real per-compilation-unit, per-image LC_UUID identity (ADR-0006
        // Finding 2/4's build-time half) — resolved through the build
        // system's own metadata (`SwiftPMCompilationUnitImageResolver`'s
        // dependency-graph reachability, or Xcode's per-target build
        // settings), never through a target-name substring match. A
        // request this stage cannot build (a malformed/missing
        // `sourceEmbeddingID` or lowerer identity on the entry itself) is
        // simply left unresolved for that one entry — `expectedImageUUIDs`
        // below falls back to the product-hash placeholder for it, the
        // same "not proven, not guessed" discipline the rest of this
        // pipeline already uses for an ambiguous mapping.
        var requestsByMutationID: [MutationID: SchemataCompilationUnitTargetRequest] = [:]
        for entry in embeddedEntries {
            guard
                let point = points[entry.mutationID],
                let sourceEmbeddingIDString = entry.sourceEmbeddingID,
                let sourceEmbeddingID = SHA256Digest(rawValue: sourceEmbeddingIDString),
                let lowererID = entry.lowererID,
                let lowererVersion = entry.lowererVersion
            else { continue }

            let compilationUnitID = CompilationUnitID.derive(
                projectIdentity: entry.projectIdentity, target: entry.target, module: entry.module,
                sourcePath: point.file, lowererID: lowererID, lowererVersion: lowererVersion
            )
            requestsByMutationID[entry.mutationID] = SchemataCompilationUnitTargetRequest(
                compilationUnitID: compilationUnitID,
                sourceEmbeddingID: sourceEmbeddingID,
                buildTarget: BuildTargetIdentity(projectIdentity: entry.projectIdentity, targetName: entry.target, moduleName: entry.module)
            )
        }

        // Two mutations in the same file (same target/module/lowerer) share
        // one compilation unit — `SchemataBuildReceipt` rightly refuses a
        // duplicate `CompilationUnitID`, so the request list passed to the
        // resolver is deduplicated by that ID before the call, not per
        // mutation.
        var uniqueRequestsByUnit: [CompilationUnitID: SchemataCompilationUnitTargetRequest] = [:]
        for request in requestsByMutationID.values {
            uniqueRequestsByUnit[request.compilationUnitID] = request
        }

        let receiptContext = SchemataBuildReceiptContext(
            planID: planID, workUnitID: workUnitID, chunkID: program.chunkID,
            toolchainHash: toolchainHash, buildArgumentsHash: buildArgumentsHash
        )
        // `SchemataBuildable.resolveSchemataBuildReceipt`'s own protocol
        // contract: fail closed (throw) when the built image cannot be
        // resolved to a provably unique identity — never resolve
        // ambiguously and never stand in a placeholder. A previous version
        // of this call absorbed that throw via a bare `try?`, letting the
        // chunk proceed with `receipt: nil` and every one of its
        // mutations scored (or not) with no proof of which built image
        // they actually reached. Receipt resolution failing is not a
        // per-mutant infrastructure failure — it means schemata itself
        // cannot vouch for this chunk at all, so every `MutationID` it
        // covers falls back to isolated mode as a whole, the identical
        // all-or-nothing shape `.sharedChunkBuildFailure` already uses for
        // a genuine compile failure.
        do {
            let receipt = try await build.resolveSchemataBuildReceipt(
                for: Array(uniqueRequestsByUnit.values), artifact: artifact, in: sandbox, context: receiptContext
            )
            return .ready(ChunkExecutionState(sandbox: sandbox, artifact: artifact, receipt: receipt))
        } catch {
            return .failed(
                embeddedEntries.map { .isolatedFallback(mutationID: $0.mutationID, reason: .buildReceiptUnavailable) },
                infrastructureFallbackEvent: SchemataInfrastructureFallbackEvent(
                    chunkID: program.chunkID, reason: .buildReceiptUnavailable,
                    affectedMutationCount: embeddedEntries.count,
                    diagnosis: "the chunk's own build receipt could not be resolved: \(error)"
                )
            )
        }
    }

    /// ADR-0008 §2 Option B item 1 / §3.2: the containment mechanism. Called
    /// whenever a forced timeout-kill (primary or confirmation run) is
    /// observed, for every not-yet-finalized entry the caller passes in
    /// `remainingEntries` — never a subset the caller forgot to include,
    /// since the caller (the `runEntries` scheduler) is the only place that
    /// knows which entries are still unresolved. Unconditional: the
    /// existing sandbox/build product is discarded and never reused,
    /// regardless of whether the timeout that triggered this call is later
    /// classified `.verifiedTimeout` or `.flaky` — that classification
    /// question belongs to `MutationVerdictVerifier` alone (ADR-0008 §3.1)
    /// and is never consulted here.
    ///
    /// Sandbox recreation reuses `program.chunkID` — `WorkspaceManager
    /// .createSandbox(id:)` is deterministic by `id`, so destroy-then-create
    /// under the same chunk ID always yields the same directory, freshly
    /// emptied. The rebuild itself (once a fresh sandbox exists) routes
    /// through the exact same `prepareChunkState` every initial chunk build
    /// already uses, so a mid-chunk recovery rebuild failure is handled by
    /// the identical four-way split (ADR-0008 §4(d)), never a separately
    /// maintained duplicate.
    private func rebuildChunkState(
        program: SchemataProgram, entries remainingEntries: [SchemataPlanEntry], state: ChunkExecutionState
    ) async -> ChunkPreparationOutcome {
        try? await workspaces.destroySandbox(at: state.sandbox)
        let sandbox: URL
        do {
            let sandboxCreateStart = GateTimingRecorder.shared.now()
            sandbox = try await workspaces.createSandbox(id: program.chunkID)
            await GateTimingRecorder.shared.record("chunk.sandboxCreate", chunkID: program.chunkID, start: sandboxCreateStart)
        } catch {
            return .failed(remainingEntries.compactMap {
                infrastructureFailureResult(for: $0, reason: "the recovery sandbox could not be recreated: \(error)")
            }.map(EntryRunOutcome.verified))
        }
        return await prepareChunkState(program: program, entries: remainingEntries, in: sandbox)
    }

    /// The same derivation `runChunk`'s build-receipt resolution and the
    /// lowerer itself (`BoolLiteralSchemataLowerer.lower`) use — real
    /// compilation-unit identity, never a placeholder. Computed directly
    /// from `entry`/`point` (not read back from `runChunk`'s own per-entry
    /// request map) so this holds even for an entry that map left
    /// unresolved (a malformed `sourceEmbeddingID`, say): the chain check
    /// still has a real, derived unit to check the runtime's own report
    /// against, exactly mirroring `embeddingEvidence`'s existing
    /// `entry.lowererID ?? "unknown"` fallback discipline.
    private static func compilationUnitID(for entry: SchemataPlanEntry, point: MutationPoint) -> CompilationUnitID {
        CompilationUnitID.derive(
            projectIdentity: entry.projectIdentity, target: entry.target, module: entry.module,
            sourcePath: point.file, lowererID: entry.lowererID ?? "unknown", lowererVersion: entry.lowererVersion ?? 0
        )
    }

    private static func targetIdentity(for entry: SchemataPlanEntry) -> TargetExecutionIdentity {
        TargetExecutionIdentity(
            projectIdentity: entry.projectIdentity, target: entry.target, module: entry.module, product: entry.product
        )
    }

    /// Mirrors `MutationRunner.finalize` (ADR-0006 Stage 1): the schemata
    /// path's single choke point from raw observations to a verified
    /// record. Unlike `MutationRunner`, this returns the
    /// `VerifiedMutationRecord` itself rather than a projected
    /// `MutationResult` — `run()` needs every target's own record intact
    /// to build `MultiTargetVerdict`s before any one of them is picked for
    /// display.
    private func finalize(
        point: MutationPoint,
        sourceApplication: SourceApplicationOutcome? = nil,
        build: BuildObservation? = nil,
        test: SingleTestObservation? = nil,
        confirmations: [ConfirmationObservation] = [],
        infrastructureFailureDiagnosis: String? = nil
    ) -> VerifiedMutationRecord {
        let ref = PlannedMutationRef.forPoint(point, planID: planID, workUnitID: workUnitID)
        let observations = MutationObservations(
            plannedMutation: ref,
            sourceApplication: sourceApplication,
            build: build,
            coverage: nil,
            test: test,
            confirmations: confirmations,
            infrastructureFailureDiagnosis: infrastructureFailureDiagnosis
        )
        return MutationVerdictVerifier.verify(observations, policy: policy)
    }

    /// The same `MutationObservations` shape `finalize` will eventually
    /// verify, built early so `runEntry` can ask `MutationVerdictVerifier
    /// .confirmationRequirement` whether a confirmation is needed *before*
    /// deciding to gather one — mirrors `finalize`'s own construction
    /// exactly (confirmations always empty here; that is the question this
    /// exists to answer, not something it can already know).
    private func preliminaryObservations(
        point: MutationPoint, sourceApplication: SourceApplicationOutcome, build: BuildObservation, test: SingleTestObservation
    ) -> MutationObservations {
        MutationObservations(
            plannedMutation: PlannedMutationRef.forPoint(point, planID: planID, workUnitID: workUnitID),
            sourceApplication: sourceApplication, build: build, coverage: nil, test: test
        )
    }

    // MARK: - Per chunk: the entry scheduler (ADR-0008)

    /// Runs every entry in a chunk in order, owning both ADR-0008 trigger
    /// points that `runPrimary`/`runConfirmation` cannot see on their own:
    /// **Trigger 1** (containment before a confirmation that follows a
    /// primary forced timeout-kill — unconditional, never skipped) and
    /// **Trigger 2** (containment before the *next* entry, only when there
    /// is a next entry to protect — ADR-0008 §5 item 2's "no wasted
    /// rebuild"). `state` is reassigned, never mutated in place, each time
    /// a rebuild succeeds; a rebuild failure reports §4(d)'s failure
    /// outcomes for every entry it was asked to protect and ends the
    /// chunk's loop immediately (nothing further is spawned against a
    /// sandbox this chunk failed to recover).
    ///
    /// Receives the live `tracker` actor, not a value snapshotted before
    /// this chunk began: the hang-budget-overflow check below reads it
    /// fresh, at the exact moment overflow actually fires, precisely so a
    /// concurrently-running sibling chunk's later mid-run fold-in is never
    /// missed by a start-of-chunk snapshot that has since gone stale.
    private func runEntries(
        _ embeddedEntries: [SchemataPlanEntry], program: SchemataProgram, state initialState: ChunkExecutionState,
        timeoutController: TimeoutController,
        perTestCoverage: PerTestCoverageMap?,
        coverage: CoverageMap?,
        expectedPlacementsByMutationID: [MutationID: Int],
        tracker: CompletedPlacementsTracker
    ) async -> ChunkRunResult {
        var state = initialState
        var results: [EntryRunOutcome] = []
        var buildFailureEvents: [SharedChunkBuildFailureEvent] = []
        var infrastructureFallbackEvents: [SchemataInfrastructureFallbackEvent] = []
        // Bundles the three accumulators above at whatever point a caller
        // below needs to return early — kept as one function so a later
        // fourth accumulator never needs its own 1-line change repeated at
        // every one of this loop's several early-return sites. Positional,
        // via `ChunkRunResult`'s own convenience `init` — see its doc
        // comment.
        func currentResult() -> ChunkRunResult { ChunkRunResult(results, buildFailureEvents, infrastructureFallbackEvents) }
        // ADR-0008 §3.3: increments only on a verifier-confirmed
        // `.verifiedTimeout`, never on a raw forced kill — a primary timeout
        // whose confirmation resolves normally stays `.flaky` and must never
        // count against this budget (see items 1/6's own tests).
        var hangBudgetCount = 0

        // Resolve as many entries' primary observations as possible via one
        // shared batched invocation, before the sequential scheduler below
        // ever starts. Every entry with a value here has *already* run —
        // the loop substitutes it directly instead of calling `runPrimary`.
        // Every entry *without* one (batching unsupported, ineligible, or
        // disabled) falls through to the existing per-entry call,
        // completely unchanged. Fetched once, against `initialState`:
        // entries covered here already have their final primary result
        // before ADR-0008's Trigger 1/2 rebuild logic ever runs for this
        // chunk, so a later rebuild (triggered by some *other* entry's own
        // timeout) never needs to touch, invalidate, or re-fetch them —
        // see `prepareBatchedPrimaries`'s own doc comment for why their
        // results remain valid regardless.
        let batchedPrimaries = await prepareBatchedPrimaries(
            embeddedEntries, state: initialState, timeoutController: timeoutController,
            perTestCoverage: perTestCoverage, coverage: coverage
        )

        /// Performs a mid-chunk rebuild for `remainingEntries` and folds the
        /// result into `state`/`results`. Returns `false` when the rebuild
        /// itself failed (§4(d)) — the caller must stop iterating in that
        /// case, since every entry this call was protecting has already been
        /// given its final `EntryRunOutcome` for this chunk: a verdict-
        /// bearing failure outcome for the two shapes that are genuine
        /// failures (sandbox-creation error, untyped build error), an
        /// `.isolatedFallback(reason: .sharedChunkBuildFailure)` — never a
        /// fabricated verdict — for a typed `BuildFailure` (Addendum 4), or
        /// an `.isolatedFallback(reason: .buildReceiptUnavailable)` when the
        /// rebuild succeeded but its own receipt could not be resolved.
        func rebuild(protecting remainingEntries: [SchemataPlanEntry]) async -> Bool {
            switch await rebuildChunkState(program: program, entries: remainingEntries, state: state) {
            case let .failed(failureOutcomes, buildFailureEvent, infrastructureFallbackEvent):
                results.append(contentsOf: failureOutcomes)
                if let buildFailureEvent { buildFailureEvents.append(buildFailureEvent) }
                if let infrastructureFallbackEvent { infrastructureFallbackEvents.append(infrastructureFallbackEvent) }
                return false
            case let .ready(newState):
                state = newState
                return true
            }
        }

        var index = 0
        while index < embeddedEntries.count {
            let entry = embeddedEntries[index]
            let rawTimedOut: Bool

            let primaryOutcome = if let preFetched = batchedPrimaries[entry.mutationID] {
                preFetched
            } else {
                await runPrimary(
                    entry, state: state, timeoutController: timeoutController, perTestCoverage: perTestCoverage, coverage: coverage
                )
            }

            switch primaryOutcome {
            case let .settled(outcome, primaryTimedOut):
                results.append(outcome)
                rawTimedOut = primaryTimedOut

            case let .needsConfirmation(handoff):
                // Trigger 1: unconditional, never skipped regardless of how
                // many entries remain — this entry's own about-to-run
                // confirmation must never reuse a sandbox a forced kill just
                // left in an unverified state.
                if handoff.primaryTimedOut {
                    guard await rebuild(protecting: Array(embeddedEntries[index...])) else { return currentResult() }
                }

                // If Trigger 1 just rebuilt, `handoff.request`'s receipt is
                // the stale, pre-rebuild one — always re-pin it to the
                // current state's receipt (a no-op when no rebuild happened)
                // rather than assume the two can never diverge.
                var request = handoff.request
                request.receipt = state.receipt
                // The SAME resolved limit the primary run this confirms
                // used — computed once in `runPrimary` from that entry's own
                // `selectedTests`, carried through `handoff`, never
                // recomputed here (and never the flat, chunk-wide fallback).
                let confirmation = await runConfirmation(
                    handoff.requirement, request: request, state: state,
                    timeoutSeconds: handoff.resolvedTimeoutSeconds,
                    selectedTests: handoff.selectedTests
                )
                // Read before `finalize` is even called (ADR-0008 §3.2: a
                // raw supervision fact, checked before any verdict exists) —
                // `rawTimedOut` here can never be influenced by, or made to
                // depend on, the verdict `finalize` is about to compute.
                rawTimedOut = confirmation.run.status == .timedOut

                let record = finalize(
                    point: handoff.point, sourceApplication: .applied(handoff.evidence),
                    build: handoff.buildObservation, test: handoff.testObservation, confirmations: [confirmation]
                )
                results.append(.verified(TargetRecord(
                    targetIdentity: handoff.targetIdentity, record: record,
                    durationSeconds: Date().timeIntervalSince(handoff.startedAt),
                    testDurationSeconds: Date().timeIntervalSince(handoff.testStartedAt)
                )))
                if record.outcome == .verifiedTimeout {
                    hangBudgetCount += 1
                }
            }

            // Hang-budget overflow (ADR-0008 §3.3/§4(b)) — checked before
            // Trigger 2: an overflowing chunk closes out everything it has
            // left unconditionally, so there is nothing left for Trigger 2
            // to protect once this fires.
            //
            // Fetched fresh, right here, right now — never a value carried
            // in from before this chunk started. A concurrently-running
            // sibling chunk that shares a `MutationID` with this one may
            // finish and fold its own contribution in at any point during
            // this chunk's run, including well after this chunk began; only
            // a read taken at the moment overflow actually fires can be
            // trusted to reflect that.
            if hangBudgetCount > maxVerifiedTimeoutsPerChunk {
                let latestCompleted = await tracker.snapshot()
                results.append(contentsOf: hangBudgetOverflowClosure(
                    embeddedEntries, upThroughIndex: index,
                    expectedPlacementsByMutationID: expectedPlacementsByMutationID,
                    completedPlacementsByMutationID: latestCompleted
                ))
                return currentResult()
            }

            // Trigger 2: only when a next entry actually exists to protect
            // (ADR-0008 §5 item 2 — rebuilding after the chunk's last spawn
            // is wasted work, verified by construction here, not assumed).
            let remaining = Array(embeddedEntries[(index + 1)...])
            if rawTimedOut, !remaining.isEmpty {
                guard await rebuild(protecting: remaining) else { return currentResult() }
            }

            index += 1
        }
        return currentResult()
    }

    /// Closes out every not-yet-fully-finalized `MutationID` in this chunk
    /// once its hang budget is exceeded (ADR-0008 §3.3/§4(b)): every entry
    /// this chunk has not yet run (`upThroughIndex+1...`, always
    /// unfinalized by definition), plus every entry this chunk *has* already
    /// run (`0...upThroughIndex`) whose `MutationID` is not yet fully
    /// finalized once this chunk's own contribution is counted —
    /// `completedPlacementsByMutationID` only reflects *other, already-
    /// returned* chunks (`run()` folds a chunk's own outcomes in only after
    /// it fully returns), so `+1` here accounts for the current chunk's own
    /// placement, per §0's fact that one `MutationID` appears at most once
    /// per chunk. A `MutationID` this closes out may already have a
    /// `.verified` entry earlier in `results` from this same chunk — that is
    /// intentional, not a bug: `run()`'s existing all-or-nothing scan drops
    /// every `.verified` record for any `MutationID` with *any*
    /// `.isolatedFallback` entry, so emitting a second entry here is exactly
    /// what makes the whole `MutationID` (not just its unfinished
    /// placements) fall back to isolated mode, with zero changes to that
    /// scan.
    private func hangBudgetOverflowClosure(
        _ embeddedEntries: [SchemataPlanEntry], upThroughIndex index: Int,
        expectedPlacementsByMutationID: [MutationID: Int], completedPlacementsByMutationID: [MutationID: Int]
    ) -> [EntryRunOutcome] {
        var outcomes: [EntryRunOutcome] = []
        for remainingEntry in embeddedEntries[(index + 1)...] {
            outcomes.append(.isolatedFallback(mutationID: remainingEntry.mutationID, reason: .hangBudgetExceeded))
        }
        for seenEntry in embeddedEntries[0 ... index] {
            let priorCount = completedPlacementsByMutationID[seenEntry.mutationID] ?? 0
            let expected = expectedPlacementsByMutationID[seenEntry.mutationID] ?? 1
            if priorCount + 1 < expected {
                outcomes.append(.isolatedFallback(mutationID: seenEntry.mutationID, reason: .hangBudgetExceeded))
            }
        }
        return outcomes
    }

    // MARK: - Per mutant

    /// What `runPrimary` produced for one entry: either a fully resolved
    /// outcome (`.settled` — no confirmation was needed, or none could be
    /// gathered), or everything `runEntries` needs to gather a confirmation
    /// itself (`.needsConfirmation`) — confirmation dispatch is owned by the
    /// scheduler, not by this function, specifically so the scheduler can
    /// interpose a containment rebuild between the primary run and the
    /// confirmation run when ADR-0008 requires one (Trigger 1).
    private enum PrimaryOutcome {
        case settled(EntryRunOutcome, primaryTimedOut: Bool)
        case needsConfirmation(ConfirmationHandoff)
    }

    /// Everything `runEntries` needs to gather and finalize a confirmation
    /// for one entry, once `runPrimary` has determined one is required —
    /// the primary run's own evidence, captured once and threaded through
    /// unchanged (a confirmation never re-derives it), plus `primaryTimedOut`
    /// so the scheduler knows whether Trigger 1 applies without re-deriving
    /// it from `testObservation.run.status` itself.
    private struct ConfirmationHandoff {
        let requirement: ConfirmationRequirement
        let request: ConfirmationRequest
        let point: MutationPoint
        let evidence: MutationEvidence
        let buildObservation: BuildObservation
        let testObservation: SingleTestObservation
        let targetIdentity: TargetExecutionIdentity
        let startedAt: Date
        let testStartedAt: Date
        let primaryTimedOut: Bool
        /// The exact same selection the primary run itself used — never
        /// recomputed or widened for the confirmation. A confirmation
        /// re-tests the same mutant to verify a kill/timeout is real, not a
        /// fluke, so it must exercise the same tests the primary run did.
        let selectedTests: Set<TestIdentifier>?
        /// The exact per-mutant limit the primary run itself was resolved
        /// against (`TimeoutController.mutantLimitSeconds(selectedTests:
        /// coverage:)`, computed once in `runPrimary`) — carried through so
        /// the confirmation run reuses it verbatim instead of re-resolving
        /// it, which the confirmation's own artifact/sandbox context has no
        /// business doing differently from the run it is confirming.
        let resolvedTimeoutSeconds: Double
    }

    /// Everything about one entry that is known *before* its primary test
    /// process ever runs — resolved once, whether that run turns out to be
    /// an individual `runSchemataToken` call (today's only path) or a
    /// Everything about one entry that is known *before* its primary test
    /// process ever runs — resolved once, whether that run turns out to be
    /// an individual `runSchemataToken` call (today's only path) or a
    /// looked-up member of a shared batch call: the two origins share this
    /// exact same shape, so `processPrimaryObservation` never needs to know
    /// or care which one produced its `TestRunResult`.
    private struct PrimaryDispatch {
        let token: SchemataSelectorToken
        let sourceEmbeddingID: SHA256Digest
        let point: MutationPoint
        let compilationUnitID: CompilationUnitID
        let selectedTests: Set<TestIdentifier>?
        let resolvedTimeoutSeconds: Double
        let runID: RunID
        let evidenceDirectory: URL
        let transcriptPath: URL
        let started: Date
        let testStarted: Date
    }

    /// `prepareDispatch`'s result: either this entry is already fully
    /// decided without ever running a test (`.settled` — the
    /// `knownUncovered` fast path), or it is ready to be dispatched — by
    /// either caller shape — for a real token run.
    private enum PrimaryDispatchOutcome {
        case settled(PrimaryOutcome)
        case dispatched(PrimaryDispatch)
    }

    /// The pre-run half of what used to be `runPrimary` end to end: every
    /// guard, precondition, and pure-logic resolution that must happen
    /// *before* a token is ever dispatched — unchanged in content or order
    /// from the original function, only extracted so a batched caller can
    /// resolve every entry's own dispatch up front, before deciding how to
    /// group them, without duplicating any of this reasoning.
    private func prepareDispatch(
        _ entry: SchemataPlanEntry, state: ChunkExecutionState, timeoutController: TimeoutController,
        perTestCoverage: PerTestCoverageMap?, coverage: CoverageMap?
    ) -> PrimaryDispatchOutcome {
        // `token`/`sourceEmbeddingID` are always non-nil here: `entries` was
        // already filtered to `isEmbedded` entries by the caller, and both
        // are only ever `nil` for `.isolatedFallback` placements. `point`
        // is a caller contract, not a runtime condition: `points` must
        // cover every `MutationID` in `programs`, the same completeness
        // `SchemataPlan.decodeAndValidate` already enforces between a plan
        // and its entries.
        guard
            let token = entry.selectorToken, let sourceEmbeddingIDString = entry.sourceEmbeddingID,
            let sourceEmbeddingID = SHA256Digest(rawValue: sourceEmbeddingIDString)
        else {
            preconditionFailure("a schemata-embedded entry must carry a selector token and source embedding ID")
        }
        guard let point = points[entry.mutationID] else {
            preconditionFailure("no MutationPoint supplied for embedded mutation \(entry.mutationID.rawValue)")
        }
        let compilationUnitID = Self.compilationUnitID(for: entry, point: point)

        // Fast path: a baseline coverage map that already proves this line
        // was never executed makes a schemata token attempt pointless —
        // isolated mode would reach the identical `.noCoverage` verdict for
        // free (`MutationRunner.prepare(...)`'s own identical check), so
        // this entry is routed to isolated fallback *before* paying for a
        // build-already-done-but-test-still-real token run, not after
        // discovering the same fact via `noStartup` (see
        // `SchemataFallbackReason.knownUncovered`'s own doc comment).
        if let coverage, coverage.isKnownUncovered(point) {
            return .settled(.settled(.isolatedFallback(mutationID: entry.mutationID, reason: .knownUncovered), primaryTimedOut: false))
        }

        // An empty result is never used: it would mean "run nothing", which
        // a coverage-blind run can't tell apart from a mutant with no
        // covering test at all. `nil` — unknown attribution, or none
        // configured — always falls back to the full configured test list
        // inside the adapter, mirroring `MutationRunner`'s own lookup at its
        // equivalent call site exactly.
        let selectedTests = perTestCoverage
            .flatMap { $0.testsCovering(file: point.file, line: point.line) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // Selected-test-clamped when this entry has a known, non-empty
        // selection, the same whole-suite-scaled fallback isolated mode uses
        // otherwise — resolved once, here, and reused verbatim by this
        // entry's confirmation (see `ConfirmationHandoff
        // .resolvedTimeoutSeconds`), never recomputed downstream.
        let resolvedTimeoutSeconds = timeoutController.mutantLimitSeconds(selectedTests: selectedTests)

        let started = Date()
        let runID = RunID()
        let evidenceDirectory = state.sandbox.appendingPathComponent(".mutantkit-schemata/\(entry.mutationID.rawValue)")
        let transcriptPath = evidenceDirectory.appendingPathComponent("transcript.bin")
        try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)

        return .dispatched(PrimaryDispatch(
            token: token, sourceEmbeddingID: sourceEmbeddingID, point: point, compilationUnitID: compilationUnitID,
            selectedTests: selectedTests, resolvedTimeoutSeconds: resolvedTimeoutSeconds, runID: runID,
            evidenceDirectory: evidenceDirectory, transcriptPath: transcriptPath, started: started, testStarted: Date()
        ))
    }

    /// Collects raw observations only (ADR-0006 Stage 2) — this runner
    /// decides nothing about whether the mutation was proven built,
    /// selected, or hit. It runs the process, reads back whatever
    /// transcript it wrote (however empty or malformed), and hands the
    /// whole unfiltered result to `MutationVerdictVerifier
    /// .verifySchemataChain` inside a `SchemataExecutionObservation` —
    /// the only place that chain is ever built or judged.
    ///
    /// Never dispatches a confirmation itself (ADR-0008): whether one is
    /// needed is decided here, but gathering it — and, when required,
    /// interposing a containment rebuild first — is `runEntries`' job, since
    /// only the scheduler knows what else remains in the chunk to protect.
    ///
    /// Orchestrates `prepareDispatch` + an individual `runSchemataToken`
    /// call + `processPrimaryObservation` — the unbatched path every entry
    /// still takes today. A batched caller calls
    /// `prepareDispatch`/`processPrimaryObservation` directly instead,
    /// substituting a shared `runSchemataTokenBatch` call for the
    /// individual one in between; nothing in either helper changes to
    /// support that.
    private func runPrimary(
        _ entry: SchemataPlanEntry, state: ChunkExecutionState, timeoutController: TimeoutController,
        perTestCoverage: PerTestCoverageMap?, coverage: CoverageMap?
    ) async -> PrimaryOutcome {
        let dispatch: PrimaryDispatch
        switch prepareDispatch(entry, state: state, timeoutController: timeoutController, perTestCoverage: perTestCoverage, coverage: coverage) {
        case let .settled(outcome): return outcome
        case let .dispatched(resolved): dispatch = resolved
        }

        let tokenSpanStart = GateTimingRecorder.shared.now()
        let run: TestRunResult
        do {
            run = try await runSchemataToken(
                state.artifact, in: state.sandbox, token: dispatch.token, transcriptPath: dispatch.transcriptPath, runID: dispatch.runID,
                timeoutSeconds: dispatch.resolvedTimeoutSeconds, selectedTests: dispatch.selectedTests
            )
        } catch {
            await GateTimingRecorder.shared.record(
                "token.total.failed", chunkID: state.sandbox.lastPathComponent, mutationID: entry.mutationID.rawValue, start: tokenSpanStart
            )
            try? FileManager.default.removeItem(at: dispatch.evidenceDirectory)
            return processLaunchFailure(entry, point: dispatch.point, startedAt: dispatch.started, error: error)
        }
        await GateTimingRecorder.shared.record(
            "token.total", chunkID: state.sandbox.lastPathComponent, mutationID: entry.mutationID.rawValue, start: tokenSpanStart
        )

        return await processPrimaryObservation(entry, dispatch: dispatch, run: run, state: state)
    }

    /// The post-run half of what used to be `runPrimary` end to end —
    /// unchanged in content, order, or meaning from the original function's
    /// tail, only reading `run`/`dispatch`'s fields where it used to read
    /// locals of the same name. Deletes `dispatch.evidenceDirectory`
    /// itself, after reading the transcript from it (`schemataObservation`)
    /// — the same lifetime the original function's `defer` gave it, just no
    /// longer expressible as a `defer` once `run` can arrive from a batch
    /// lookup made by a *different* function than the one that created
    /// this directory.
    private func processPrimaryObservation(
        _ entry: SchemataPlanEntry, dispatch: PrimaryDispatch, run: TestRunResult, state: ChunkExecutionState
    ) async -> PrimaryOutcome {
        defer { try? FileManager.default.removeItem(at: dispatch.evidenceDirectory) }

        let expectation = SchemataRunExpectation(
            mutationID: entry.mutationID, compilationUnitID: dispatch.compilationUnitID, sourceEmbeddingID: dispatch.sourceEmbeddingID,
            selectorToken: dispatch.token, runID: dispatch.runID
        )
        let observation = schemataObservation(transcriptPath: dispatch.transcriptPath, expectation: expectation, receipt: state.receipt)

        let sourceLevel = sourceLevelEvidence(for: dispatch.point)
        let evidence = MutationEvidence(
            sourceBeforeHash: sourceLevel.beforeHash,
            sourceAfterHash: sourceLevel.afterHash,
            sourceDiff: sourceLevel.diff,
            buildProductHash: state.artifact.productHash,
            applicationEvidence: .schemata(observation),
            buildCommand: state.artifact.command,
            testCommand: run.command
        )
        let buildObservation = BuildObservation(
            outcome: .succeeded(buildProductHash: state.artifact.productHash, command: state.artifact.command)
        )
        let testObservation = SingleTestObservation(run: run, applicationEvidence: .schemata(observation))

        let preliminary = preliminaryObservations(
            point: dispatch.point, sourceApplication: .applied(evidence), build: buildObservation, test: testObservation
        )

        // Checked before `confirmationRequirement` is even asked (Group 2:
        // no-HIT/no-STARTUP -> isolated fallback): a passing test with no
        // proof this mutation was ever selected/hit gets no confirmation
        // gathered and no `finalize` call here at all — `run()` drops
        // every target placement for this MutationID and
        // `SchemataRunOrchestration` re-runs it through isolated mode from
        // scratch, which will build its own, independent proof chain.
        // Never widen this beyond what `schemataIsolatedFallbackReason`
        // itself already scopes to (see that function's own doc comment) —
        // in particular, this routing is scoped to *passing* runs, so
        // `run.status == .timedOut` here is always false in practice; kept
        // as a real check rather than a hardcoded `false` so this stays
        // correct even if that scoping ever changes.
        if let reason = MutationVerdictVerifier.schemataIsolatedFallbackReason(for: preliminary) {
            // Diagnostic only (see `GateTimingRecorder`'s own doc comment)
            // — for each transcript record present but not matching what
            // this token expected, which field(s) actually differ: a
            // different `compilationUnitID`/token (another mutation in the
            // same chunk registered/hit instead) versus a different `runID`
            // (evidence from a stale or unrelated invocation). One span per
            // record, not one summary string, so each is independently
            // readable.
            for (index, record) in observation.transcript.records.enumerated() {
                let (kind, runID, unitID, tok): (String, RunID, CompilationUnitID?, SchemataSelectorToken) = switch record {
                case let .startup(event): ("startup", event.runID, event.compilationUnitID, event.token)
                case let .hit(event): ("hit", event.runID, event.compilationUnitID, event.token)
                case let .loaded(event): ("loaded", event.runID, nil, event.token)
                }
                let runIDMatch = runID == expectation.runID ? "runID=match" : "runID=DIFFERENT(\(runID.rawValue))"
                let unitMatch = switch unitID {
                case nil: "unit=none"
                case expectation.compilationUnitID?: "unit=match"
                case let unitID?: "unit=DIFFERENT(\(unitID))"
                }
                let tokenMatch = tok == expectation.selectorToken ? "token=match" : "token=DIFFERENT(\(tok))"
                await GateTimingRecorder.shared.record(
                    "dynamicFallback.activation.\(reason).record[\(index)] kind=\(kind) \(runIDMatch) \(unitMatch) \(tokenMatch)",
                    mutationID: entry.mutationID.rawValue, start: GateTimingRecorder.shared.now()
                )
            }
            await GateTimingRecorder.shared.record(
                "dynamicFallback.activation.\(reason) selectedTests=\(dispatch.selectedTests?.count.description ?? "nil") "
                    + "transcriptRecords=\(observation.transcript.records.count) expectedRunID=\(expectation.runID.rawValue) "
                    + "expectedUnit=\(expectation.compilationUnitID) expectedToken=\(expectation.selectorToken)",
                mutationID: entry.mutationID.rawValue, start: GateTimingRecorder.shared.now()
            )
            return .settled(
                .isolatedFallback(mutationID: entry.mutationID, reason: .activation(reason)),
                primaryTimedOut: run.status == .timedOut
            )
        }

        // The same single source of truth `MutationRunner`'s own
        // confirmation gates ultimately encode — never a policy check this
        // runner re-derives on its own (ADR-0006 Stage 3).
        //
        // Never a cascade of more than one confirmation, unlike
        // `MutationConfirmationCoordinator.confirmTimeout`'s own nested `retestKilledMutants`/
        // `confirmCrashKills` calls: that cascade only fires for a
        // *batch-attributed* timeout (`TestRunResult.isBatchAttributedTimeout`,
        // set only by isolated mode's own `runBatch`). Schemata batching
        // never sets it either — `runSchemataTokenBatch`'s own results,
        // like `runSchemataToken`'s, are individually attributed per
        // `MutationID` from the start, never an ambiguous batch-wide
        // placeholder — so a schemata timeout's own `isBatchAttributedTimeout`
        // is always `false` whether or not this entry's primary came from a
        // batch call, and `MutationVerdictVerifier.confirmTimeout`'s cascade
        // branch stays structurally unreachable here: a schemata timeout
        // confirmation that finishes normally is `.flaky`, exactly like
        // isolated mode's own non-batch-attributed case, never promoted to
        // a kill — proven by `SchemataConfirmationCrashTimeoutVerifierTests
        // .timeoutConfirmationFinishingNormallyIsFlakyNotCascaded`. There is
        // therefore no second confirmation for this runner to ever gather.
        let requirement = MutationVerdictVerifier.confirmationRequirement(for: preliminary, policy: policy)
        let primaryTimedOut = run.status == .timedOut

        guard requirement != .none else {
            let record = finalize(
                point: dispatch.point, sourceApplication: .applied(evidence), build: buildObservation, test: testObservation
            )
            return .settled(.verified(TargetRecord(
                targetIdentity: Self.targetIdentity(for: entry),
                record: record,
                durationSeconds: Date().timeIntervalSince(dispatch.started),
                testDurationSeconds: Date().timeIntervalSince(dispatch.testStarted)
            )), primaryTimedOut: primaryTimedOut)
        }

        let request = ConfirmationRequest(
            mutationID: entry.mutationID, compilationUnitID: dispatch.compilationUnitID, sourceEmbeddingID: dispatch.sourceEmbeddingID,
            token: dispatch.token, receipt: state.receipt, originalFailingTests: run.summary?.failingTests, originalDiagnosis: run.diagnosis
        )
        return .needsConfirmation(ConfirmationHandoff(
            requirement: requirement, request: request, point: dispatch.point, evidence: evidence,
            buildObservation: buildObservation, testObservation: testObservation,
            targetIdentity: Self.targetIdentity(for: entry), startedAt: dispatch.started, testStartedAt: dispatch.testStarted,
            primaryTimedOut: primaryTimedOut, selectedTests: dispatch.selectedTests,
            resolvedTimeoutSeconds: dispatch.resolvedTimeoutSeconds
        ))
    }

    /// Resolves as many `embeddedEntries` as possible into already-run
    /// `PrimaryOutcome`s via one or more shared `runSchemataTokenBatch`
    /// calls, before `runEntries`' sequential per-entry scheduler ever
    /// starts. Every `MutationID` this returns a value for has already been
    /// dispatched — the caller substitutes it directly; every entry absent
    /// from the result (batching unsupported, ineligible, or disabled) is
    /// untouched and falls through to `runEntries`' existing individual
    /// `runPrimary` call, exactly as before batching existed.
    ///
    /// Never revisited once returned: entries covered here have their
    /// *final* primary result before ADR-0008's Trigger 1/2 rebuild logic
    /// runs for anything in this chunk. A later rebuild — triggered by some
    /// *other* entry's own timeout, individual or (once containment fires)
    /// native — never needs to touch these: each one's own evidence chain
    /// (`compilationUnitID`/`runID`/`sourceEmbeddingID`/token matching,
    /// enforced identically for a batched or unbatched primary) already
    /// proves its own result independently of whatever a sibling
    /// configuration in the same batch did. Confirmed directly, not
    /// assumed: real acceptance evidence is a batch where a sibling
    /// configuration's hang did not affect another configuration's
    /// already-passing result, an unrelated `xcodebuild` invocation from
    /// this runner's perspective in every way that matters here. Trigger
    /// 1/2's actual purpose — protecting a *future, not-yet-run* individual
    /// spawn from a shared sandbox a forced kill may have left unverified —
    /// is simply moot for an entry whose primary already ran as part of
    /// this same batch; it still fires, unweakened, for that entry's own
    /// *confirmation* (always an individual, never-batched run — batching
    /// never touches confirmation dispatch at all) and for any entry in a
    /// later, not-yet-dispatched batch group.
    private func prepareBatchedPrimaries(
        _ embeddedEntries: [SchemataPlanEntry], state: ChunkExecutionState, timeoutController: TimeoutController,
        perTestCoverage: PerTestCoverageMap?, coverage: CoverageMap?
    ) async -> [MutationID: PrimaryOutcome] {
        // `<= 1` (the default): batching disabled outright, the same
        // opt-in-by-default-value convention `workers` uses. Adapter
        // conformance is optional, mirroring `BatchTestable`: one that does
        // not conform simply never gets asked, and every entry runs the
        // unbatched way exactly as it always has.
        guard schemataTokenBatchSize > 1, let batchable = test as? any SchemataBatchTestable else { return [:] }

        var dispatchesByMutationID: [MutationID: PrimaryDispatch] = [:]
        for entry in embeddedEntries {
            guard
                case let .dispatched(dispatch) = prepareDispatch(
                    entry, state: state, timeoutController: timeoutController, perTestCoverage: perTestCoverage, coverage: coverage
                ),
                // A token with more than one selected test can
                // independently hang on *any* of them — native per-test
                // timeout catches each one correctly, but a batch
                // containing such a token still pays up to
                // `coveringTests × mutantLimitSeconds` for it, confirmed
                // against a real production app. Isolated mode's fix for
                // the equivalent case was wave-based early-abort, which
                // schemata batching has no analogue of — rather than build
                // one for a lever token batching already measured at only
                // ~3% overall, only a token whose own selection is exactly
                // one test is eligible to share a batch: native timeout can
                // then only ever fire once for that mutant's own
                // configuration, so no batch member can cost more than its
                // own `mutantLimitSeconds`. A multi-test token still runs —
                // through the existing, unaffected unbatched
                // `runPrimary`/`runSchemataToken` path, whose own
                // per-mutant outer timeout already bounds it without any
                // cascade risk.
                let selectedTests = dispatch.selectedTests, selectedTests.count == 1
            else { continue }
            dispatchesByMutationID[entry.mutationID] = dispatch
        }

        // A "batch" of one has no containment benefit over the unbatched
        // path (the same single-member skip isolated mode's own
        // `testOneBatch`/`testWaveChunk` already applies) — and every other
        // entry (ineligible, or the sole eligible one here) still needs to
        // run through `runPrimary`'s own, unaffected `prepareDispatch` call,
        // so any evidence directory already created above must be cleaned
        // up now rather than left for `runPrimary` to silently overwrite.
        guard dispatchesByMutationID.count > 1 else {
            for dispatch in dispatchesByMutationID.values {
                try? FileManager.default.removeItem(at: dispatch.evidenceDirectory)
            }
            return [:]
        }

        // Every eligible entry resolves to the identical limit today
        // (`TimeoutController.mutantLimitSeconds(selectedTests:)` no longer
        // varies by selection width — see its own doc comment); asserted
        // here, not assumed, so a future divergence fails this batch
        // attempt closed (falls through to the unbatched path for
        // everything) rather than silently mis-timing one entry against
        // another's budget.
        let resolvedAllowances = Set(dispatchesByMutationID.values.map(\.resolvedTimeoutSeconds))
        guard let sharedAllowance = resolvedAllowances.first, resolvedAllowances.count == 1 else {
            for dispatch in dispatchesByMutationID.values {
                try? FileManager.default.removeItem(at: dispatch.evidenceDirectory)
            }
            return [:]
        }
        // An empirically-validated floor — the only value ever actually
        // exercised against a real hang — mirroring
        // `MutationRunner.testOneBatch`/`testWaveChunk`'s identical guard.
        let nativeTimeoutAllowanceSeconds = sharedAllowance >= 60 ? sharedAllowance : nil

        let entriesByMutationID = Dictionary(uniqueKeysWithValues: embeddedEntries.map { ($0.mutationID, $0) })
        let dispatchGroups = dispatchesByMutationID.map { ($0.key, $0.value) }
        var outcomes: [MutationID: PrimaryOutcome] = [:]

        for chunkStart in stride(from: 0, to: dispatchGroups.count, by: schemataTokenBatchSize) {
            let group = Array(dispatchGroups[chunkStart ..< min(chunkStart + schemataTokenBatchSize, dispatchGroups.count)])
            let items = group.map { mutationID, dispatch in
                SchemataBatchTokenItem(
                    mutationID: mutationID,
                    environment: [
                        SchemataEvidenceCollector.tokenEnvironmentVariable: SchemataEvidenceCollector.tokenEnvironmentValue(for: dispatch.token),
                        SchemataEvidenceCollector.transcriptPathEnvironmentVariable: dispatch.transcriptPath.path,
                        SchemataEvidenceCollector.runIDEnvironmentVariable: SchemataEvidenceCollector.runIDEnvironmentValue(for: dispatch.runID)
                    ],
                    selectedTests: dispatch.selectedTests
                )
            }
            // The outer, aggregate fail-safe — summed across the group,
            // never replaced by `nativeTimeoutAllowanceSeconds` — mirrors
            // isolated mode's own `testOneBatch`/`testWaveChunk` batch
            // timeout exactly: if native containment somehow fails to fire
            // for some reason outside this runner's control, the outer
            // supervisor still has a generous-enough budget for every
            // member to finish normally before it would ever intervene.
            let outerTimeoutSeconds = Double(group.count) * sharedAllowance
            let tokenSpanStart = GateTimingRecorder.shared.now()
            let runs = await batchable.runSchemataTokenBatch(
                state.artifact, in: state.sandbox, items: items, timeoutSeconds: outerTimeoutSeconds,
                nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
            )
            await GateTimingRecorder.shared.record(
                "token.batch.total", chunkID: state.sandbox.lastPathComponent, start: tokenSpanStart
            )

            for (mutationID, dispatch) in group {
                guard let entry = entriesByMutationID[mutationID] else { continue }
                let run = runs[mutationID] ?? TestRunResult(
                    status: .infrastructureFailure, summary: nil, command: state.artifact.command, resultArtifactPath: nil,
                    diagnosis: "This token's outcome went unreported by the batch classifier."
                )
                // `.infrastructureFailure` from a shared batch call —
                // whether `classifyBatch` itself produced it (no
                // per-configuration evidence in the result bundle) or it
                // was synthesized just above (missing from `runs` entirely)
                // — means the *shared invocation's* attribution failed for
                // this one mutant, not that the mutant is unprovable. Every
                // other status a batch can produce (`.passed`/`.failed`/
                // `.crashed`/`.timedOut`) is an independently usable
                // observation about this configuration specifically and is
                // never retried here.
                outcomes[mutationID] = run.status == .infrastructureFailure
                    ? await recoverAmbiguousBatchedPrimary(entry, dispatch: dispatch, state: state)
                    : await processPrimaryObservation(entry, dispatch: dispatch, run: run, state: state)
            }
        }
        return outcomes
    }

    /// Recovers one batched primary whose shared invocation produced
    /// `.infrastructureFailure` — real evidence was simply never
    /// attributable to this configuration, not proof the mutant itself is
    /// unprovable (`XCResultAdapter.classify`'s own doc comment: fail-closed
    /// on missing per-configuration evidence, never guessed from aggregate
    /// counts). Isolated mode's wave path (`MutationRunner.testWaveChunk`)
    /// already does the equivalent thing for the identical failure shape;
    /// this is schemata's own version of that same discipline, not a new
    /// retry policy.
    ///
    /// A fresh, individual, unbatched `runSchemataToken` call — this
    /// mutant's own token, point, compilation unit, selected tests, and
    /// resolved timeout carried over unchanged from the ambiguous attempt's
    /// `dispatch`, but under a **new** `RunID`/transcript/evidence
    /// directory. Never the same `RunID` as the ambiguous attempt: mixing a
    /// batch's incomplete evidence with a retry's own would let
    /// `verifySchemataChain` cross-attribute records that never actually
    /// came from the same process invocation. The retry's `TestRunResult`
    /// flows through the exact same `processPrimaryObservation` every other
    /// primary observation already uses — a `.passed`/`.failed`/`.crashed`/
    /// `.timedOut` result here gets precisely the ADR-0008 handling it
    /// would have gotten had this mutant never been batched at all; no
    /// verifier semantics change. Runs at most once: a second
    /// `.infrastructureFailure` here is final, not retried again.
    private func recoverAmbiguousBatchedPrimary(
        _ entry: SchemataPlanEntry, dispatch: PrimaryDispatch, state: ChunkExecutionState
    ) async -> PrimaryOutcome {
        // The ambiguous attempt's own evidence directory was never read by
        // anything (its `TestRunResult` carried no usable schemata
        // transcript path this function trusts) and is not reused —
        // cleaned up here since `processPrimaryObservation` will only ever
        // clean up the *fresh* dispatch's directory below, not this one.
        try? FileManager.default.removeItem(at: dispatch.evidenceDirectory)

        let recoveryDirectory = state.sandbox.appendingPathComponent(
            ".mutantkit-schemata/\(entry.mutationID.rawValue)-recovery-\(UUID().uuidString)"
        )
        let transcriptPath = recoveryDirectory.appendingPathComponent("transcript.bin")
        try? FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let freshDispatch = PrimaryDispatch(
            token: dispatch.token, sourceEmbeddingID: dispatch.sourceEmbeddingID, point: dispatch.point,
            compilationUnitID: dispatch.compilationUnitID, selectedTests: dispatch.selectedTests,
            resolvedTimeoutSeconds: dispatch.resolvedTimeoutSeconds, runID: RunID(),
            evidenceDirectory: recoveryDirectory, transcriptPath: transcriptPath,
            // `started` carries over from the ambiguous attempt, not reset —
            // this mutant's total duration honestly includes the batch time
            // it already spent before its own attribution came back
            // unusable, not just the recovery's own wall clock.
            started: dispatch.started, testStarted: Date()
        )

        let recoverySpanStart = GateTimingRecorder.shared.now()
        let run: TestRunResult
        do {
            run = try await runSchemataToken(
                state.artifact, in: state.sandbox, token: freshDispatch.token, transcriptPath: freshDispatch.transcriptPath,
                runID: freshDispatch.runID, timeoutSeconds: freshDispatch.resolvedTimeoutSeconds,
                selectedTests: freshDispatch.selectedTests
            )
        } catch {
            await GateTimingRecorder.shared.record(
                "token.batchAmbiguityRecovery.failed", chunkID: state.sandbox.lastPathComponent,
                mutationID: entry.mutationID.rawValue, start: recoverySpanStart
            )
            try? FileManager.default.removeItem(at: freshDispatch.evidenceDirectory)
            return processLaunchFailure(entry, point: freshDispatch.point, startedAt: freshDispatch.started, error: error)
        }
        await GateTimingRecorder.shared.record(
            "token.batchAmbiguityRecovery.total", chunkID: state.sandbox.lastPathComponent,
            mutationID: entry.mutationID.rawValue, start: recoverySpanStart
        )

        return await processPrimaryObservation(entry, dispatch: freshDispatch, run: run, state: state)
    }

    /// One entry whose test process never even started. Not a forced
    /// timeout-kill: no `TestRunResult` was ever produced, so there is
    /// nothing for ADR-0008's containment trigger to key off, and none of
    /// the shared-sandbox residue risk it exists for applies — hence
    /// `primaryTimedOut: false`, unconditionally. Existing behavior,
    /// unaffected by this ADR; extracted from `runPrimary` only to keep that
    /// function's own body readable.
    private func processLaunchFailure(
        _ entry: SchemataPlanEntry, point: MutationPoint, startedAt started: Date, error: any Error
    ) -> PrimaryOutcome {
        .settled(.verified(TargetRecord(
            targetIdentity: Self.targetIdentity(for: entry),
            record: finalize(point: point, infrastructureFailureDiagnosis: "the test process could not be run: \(error)"),
            durationSeconds: Date().timeIntervalSince(started),
            testDurationSeconds: nil
        )), primaryTimedOut: false)
    }

    /// Thin wrapper over `confirmSchemataToken` taking a `ChunkExecutionState`
    /// rather than separate `artifact`/`sandbox` parameters, so call sites in
    /// the scheduler read against the same state value Trigger 1's rebuild
    /// may just have replaced.
    private func runConfirmation(
        _ requirement: ConfirmationRequirement, request: ConfirmationRequest, state: ChunkExecutionState,
        timeoutSeconds: Double, selectedTests: Set<TestIdentifier>?
    ) async -> ConfirmationObservation {
        await confirmSchemataToken(
            requirement, artifact: state.artifact, request: request, in: state.sandbox, timeoutSeconds: timeoutSeconds,
            selectedTests: selectedTests
        )
    }

    private struct SourceLevelEvidence {
        let beforeHash: String
        let afterHash: String
        let diff: String
    }

    private func sourceLevelEvidence(for point: MutationPoint) -> SourceLevelEvidence {
        guard let original = originalSources[point.file], let applied = try? MutationApplication.apply(point, to: original) else {
            return SourceLevelEvidence(beforeHash: point.sourceFileHash, afterHash: point.sourceFileHash, diff: "")
        }
        return SourceLevelEvidence(
            beforeHash: applied.evidence.sourceBeforeHash, afterHash: applied.evidence.sourceAfterHash, diff: applied.evidence.sourceDiff
        )
    }

    /// Used only where an entry's own `MutationPoint` may genuinely be
    /// absent (a chunk-level build/sandbox failure, before any per-mutant
    /// work starts) — `nil` when `points` has no entry for it, so the
    /// `compactMap` call sites drop it rather than fabricate a result with
    /// no anchor.
    private func infrastructureFailureResult(for entry: SchemataPlanEntry, reason: String, startedAt: Date = Date()) -> TargetRecord? {
        guard let point = points[entry.mutationID] else { return nil }
        return TargetRecord(
            targetIdentity: Self.targetIdentity(for: entry),
            record: finalize(
                point: point, sourceApplication: chunkLevelSourceApplication(for: point), infrastructureFailureDiagnosis: reason
            ),
            durationSeconds: Date().timeIntervalSince(startedAt),
            testDurationSeconds: nil
        )
    }

    /// The chunk itself failed to build or produced no product hash, so no
    /// per-mutant test ever ran — but the source-level fact that this
    /// mutation was applied to the chunk's sources is still real and
    /// computable from `originalSources`, so it is honestly reported
    /// rather than omitted.
    private func chunkLevelSourceApplication(for point: MutationPoint) -> SourceApplicationOutcome {
        let sourceLevel = sourceLevelEvidence(for: point)
        return .applied(MutationEvidence(
            sourceBeforeHash: sourceLevel.beforeHash,
            sourceAfterHash: sourceLevel.afterHash,
            sourceDiff: sourceLevel.diff,
            buildProductHash: nil,
            applicationEvidence: nil,
            buildCommand: nil,
            testCommand: nil
        ))
    }
}

// MARK: - Confirmation gathering (ADR-0006 Stage 3)

private extension SchemataMutationRunner {
    /// Runs one already-built chunk's runtime against `token`, under its own
    /// fresh `runID`/`transcriptPath` — the one place `runEntry` and
    /// `confirmSchemataToken` both launch a schemata process, so a primary
    /// run and its confirmation are built from an identical invocation
    /// shape and can never drift apart from each other by accident.
    func runSchemataToken(
        _ artifact: BuildArtifact, in sandbox: URL, token: SchemataSelectorToken, transcriptPath: URL, runID: RunID,
        timeoutSeconds: Double, selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        try await test.runSchemataToken(
            artifact, in: sandbox, timeoutSeconds: timeoutSeconds,
            environment: [
                SchemataEvidenceCollector.tokenEnvironmentVariable: SchemataEvidenceCollector.tokenEnvironmentValue(for: token),
                SchemataEvidenceCollector.transcriptPathEnvironmentVariable: transcriptPath.path,
                SchemataEvidenceCollector.runIDEnvironmentVariable: SchemataEvidenceCollector.runIDEnvironmentValue(for: runID)
            ],
            selectedTests: selectedTests
        )
    }

    /// Reads back whatever `runSchemataToken` actually wrote — empty (no
    /// transcript at all, malformed data) becomes an empty transcript,
    /// never a thrown error either caller has to handle specially: an
    /// empty transcript already fails the verifier's chain closed on its
    /// own.
    func schemataObservation(
        transcriptPath: URL, expectation: SchemataRunExpectation, receipt: SchemataBuildReceipt?
    ) -> SchemataExecutionObservation {
        let transcript = (try? SchemataEvidenceCollector.readTranscript(at: transcriptPath))
            ?? RuntimeTranscript(protocolVersion: 0, records: [])
        return SchemataExecutionObservation(expectation: expectation, buildReceipt: receipt, transcript: transcript)
    }

    /// Everything a confirmation attempt needs about the mutation it is
    /// confirming, bundled so `confirmSchemataToken` takes one thing rather
    /// than re-threading each of these individually through its own
    /// parameter list.
    struct ConfirmationRequest {
        let mutationID: MutationID
        let compilationUnitID: CompilationUnitID
        let sourceEmbeddingID: SHA256Digest
        let token: SchemataSelectorToken
        /// `var`, not `let` (ADR-0008): a request built by `runPrimary` at
        /// primary-run time carries that moment's receipt, but if Trigger 1
        /// rebuilds the chunk before this confirmation actually runs, the
        /// confirmation's own transcript is written against the *new*
        /// build's image UUID — `runEntries` must overwrite this field with
        /// the post-rebuild receipt before dispatching, or
        /// `schemataConfirmationChainProblem` will (correctly) reject the
        /// confirmation as inconsistent with a receipt from a build that no
        /// longer exists.
        var receipt: SchemataBuildReceipt?
        let originalFailingTests: [String]?
        let originalDiagnosis: String
    }

    /// Runs a genuinely independent confirmation attempt for `request`'s
    /// mutation — its own fresh `RunID`, its own transcript file, its own
    /// test process, requesting the exact same token against the exact
    /// same already-built artifact (ADR-0006 Stage 3): schemata mode never
    /// rebuilds to confirm, since the chunk's build already embeds every
    /// mutation and confirming is only ever a question of whether the
    /// runtime independently reaches and reports the same site again.
    /// Never reuses the primary run's own transcript, `RunID`, or process —
    /// `MutationVerdictVerifier.confirm` independently verifies this
    /// confirmation's own chain and refuses one that reused the original
    /// `RunID` (see `schemataConfirmationChainProblem`), so a shortcut here
    /// would only ever be caught downstream, never silently trusted.
    func confirmSchemataToken(
        _ requirement: ConfirmationRequirement, artifact: BuildArtifact, request: ConfirmationRequest, in sandbox: URL,
        timeoutSeconds: Double, selectedTests: Set<TestIdentifier>?
    ) async -> ConfirmationObservation {
        let kind: ConfirmationObservation.Kind = switch requirement {
        case .retestKilledMutant: .kill
        case .confirmCrash: .crash
        case .confirmTimeout: .timeout
        case .none: preconditionFailure("confirmSchemataToken must never be called for .none")
        }

        let runID = RunID()
        let evidenceDirectory = sandbox
            .appendingPathComponent(".mutantkit-schemata/\(request.mutationID.rawValue)-confirm-\(runID.rawValue.uuidString)")
        let transcriptPath = evidenceDirectory.appendingPathComponent("transcript.bin")
        try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }

        let run: TestRunResult
        do {
            run = try await runSchemataToken(
                artifact, in: sandbox, token: request.token, transcriptPath: transcriptPath, runID: runID,
                timeoutSeconds: timeoutSeconds, selectedTests: selectedTests
            )
        } catch {
            return ConfirmationObservation(
                kind: kind, run: Self.infrastructureFailureRun("the confirmation process could not be run: \(error)"),
                originalFailingTests: request.originalFailingTests, originalDiagnosis: request.originalDiagnosis
            )
        }

        let expectation = SchemataRunExpectation(
            mutationID: request.mutationID, compilationUnitID: request.compilationUnitID, sourceEmbeddingID: request.sourceEmbeddingID,
            selectorToken: request.token, runID: runID
        )
        let observation = schemataObservation(transcriptPath: transcriptPath, expectation: expectation, receipt: request.receipt)
        return ConfirmationObservation(
            kind: kind, run: run, schemataObservation: observation,
            originalFailingTests: request.originalFailingTests, originalDiagnosis: request.originalDiagnosis
        )
    }

    /// A synthetic run standing in for "a confirmation attempt could not
    /// even launch" — mirrors `MutationConfirmationCoordinator.infrastructureFailureRun`
    /// exactly, the same convention for the same reason: represented as an
    /// ordinary `TestRunResult` so it flows through `ConfirmationObservation`
    /// like any other confirming run.
    static func infrastructureFailureRun(_ diagnosis: String) -> TestRunResult {
        TestRunResult(
            status: .infrastructureFailure, summary: nil,
            command: CommandRecord(executable: "", arguments: [], workingDirectory: ""),
            resultArtifactPath: nil, diagnosis: diagnosis
        )
    }
}
