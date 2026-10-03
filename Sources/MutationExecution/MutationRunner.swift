import Dispatch
import Foundation
import MutationModel
import SwiftFrontend

/// Executes a plan in isolated mode and reports what it can prove.
///
/// The shape of a run is: establish a baseline, then for each planned mutation
/// build a sandbox, apply exactly one edit, build it, test it, classify it,
/// checkpoint it, and throw the sandbox away.
///
/// Two things are load-bearing:
///
/// 1. **The baseline is a gate, not a data point.** If the unmutated suite does
///    not build and pass, every mutant outcome measured against it is noise —
///    a "survived" mutant in a red suite means nothing at all. The run stops and
///    reports no score rather than producing numbers it cannot stand behind.
///
/// 2. **Order is a property of the plan, not of the schedule.** Mutants run
///    concurrently and finish in whatever order the machine decides, so results
///    are sorted back into `MutationID` order before anything reads them. Two
///    runs of the same plan produce the same report.
///
/// Everything `MutationRunner.establishConfirmationSandbox(_:startedAt:)`
/// needs, bundled so that call stays within swiftlint's parameter-count
/// limit — see that method's own doc comment for what it does with these.
private struct ConfirmationSandboxRequest {
    let point: MutationPoint
    let applied: AppliedMutation
    let artifact: BuildArtifact
    let activation: ActivationEvidence?
    let coverage: CoverageObservation?
    let buildDurationSeconds: Double
}

/// The adapters are injected: this type knows about building and testing, and
/// nothing about `xcodebuild`, `swift test`, or simulators.
public struct MutationRunner: Sendable {
    private let plan: MutationPlan
    private let configuration: Configuration
    private let projectRoot: URL
    private let toolchain: ToolchainFingerprint
    private let build: any BuildAdapter
    private let test: any TestAdapter
    private let workspaces: WorkspaceManager
    private let checkpoints: CheckpointStore?
    private let artifactsRoot: URL?
    private let coverageCache: CoverageProfileCache?
    private let coverageCacheKey: CoverageProfileCache.Key?
    private let resultCache: MutationResultCache?
    private let resultCacheDigest: String?
    private let priorityStore: TestPriorityStore?
    private let monotonicNow: @Sendable () -> TimeInterval
    private let operationalIssues = OperationalIssueLog()
    private let progress: MutationProgressReporter?
    /// When supplied, `establishBaseline()` uses this instead of building
    /// and testing the project itself — `SchemataRunOrchestration`'s own
    /// mechanism for sharing one baseline between the schemata and
    /// isolated-fallback passes (see `SharedBaselineEstablisher`'s own doc
    /// comment). `nil` for every other caller, which is every existing one:
    /// this parameter changes nothing about a plain `mutantkit run
    /// --strategy isolated`.
    private let preEstablishedBaseline: SharedBaselineEstablisher.Outcome?

    /// Retesting a decided outcome (same-artifact confirmation for a kill,
    /// fresh-rebuild confirmation for a crash or a timeout) and the
    /// test-running primitive every one of those, and this runner's own
    /// primary test run, executes through — see that type's own doc
    /// comment. Phase A1 extraction out of this type: constructed once in
    /// `init`, from the same `workspaces`/`build`/`test`/`configuration`
    /// this runner itself was given.
    private let confirmationCoordinator: MutationConfirmationCoordinator

    /// Turning raw build/test/application observations into a reportable
    /// `MutationResult` — see that type's own doc comment. Phase A1
    /// extraction out of this type: constructed once in `init`, sharing
    /// this runner's own `operationalIssues` log by reference (not a copy),
    /// so a warning `finalize` records still reaches this run's own
    /// `RunReport.operationalIssues` below.
    private let evidenceAssembler: MutationEvidenceAssembler

    /// Cannot collide with a mutant's sandbox: every mutation ID starts `mut_`.
    private static let baselineSandboxID = "baseline"

    /// - Parameters:
    ///   - checkpoints: when supplied, results are persisted as they land and
    ///     mutations already recorded there are not re-run.
    ///   - artifactsRoot: where to keep result bundles once their sandbox is
    ///     gone. Without it there is nowhere for an `.xcresult` to survive, and
    ///     the evidence records no path rather than a dangling one.
    ///   - toolchain: the toolchain doing the running, which is not necessarily
    ///     the one that did the planning. Defaults to the plan's.
    ///   - coverageCache: when supplied with `coverageCacheKey`, the baseline
    ///     pass's per-test coverage attribution is loaded from this cache
    ///     instead of re-measured when the key matches a prior run, and a
    ///     fresh measurement is stored back into it for the next run. The
    ///     baseline build and test still always run — coverage is the only
    ///     thing skipped, because every other responsibility of the baseline
    ///     (the suite-must-pass gate, the timeout calibration, the activation
    ///     hash) still has to be earned on every run.
    ///   - resultCache: when supplied with `resultCacheDigest`, a mutant whose
    ///     `MutationID` was already evaluated against an identical execution
    ///     context (same source, test suite, toolchain, configuration —
    ///     captured in the digest) is reused without rebuilding or retesting.
    ///     The baseline still always runs: the cache carries mutant verdicts,
    ///     not the suite-must-pass gate or timeout calibration those verdicts
    ///     were measured against. Checkpoint hits take priority over cache
    ///     hits — a checkpoint is always-trusted state from the same run,
    ///     while a cache entry is a cross-run inference.
    ///   - priorityStore: when supplied alongside `earlyAbortSelectedTests`
    ///     and `testBatchSize`, the test phase uses wave-based early kill
    ///     instead of ordinary batching: each wave batch-tests one
    ///     prioritised covering test per surviving mutant, and a mutant
    ///     that fails its wave's test is killed and drops out rather than
    ///     running its remaining covering tests — see `testInWaves`. Without
    ///     a store, batched testing runs every mutant's full selection in
    ///     one shot per `testAndFinish`, unchanged; early abort is then only
    ///     available through the CLI's per-invocation `PrioritizingTestAdapter`
    ///     wrapping, which does not require batching at all.
    ///   - monotonicNow: what the wave loop's cumulative-budget measurement
    ///     (`testWaveChunk`/`standaloneVerify`) reads elapsed time from.
    ///     Defaults to a monotonic uptime clock — never `Date`/wall-clock
    ///     time, which can jump backward or forward under a clock
    ///     correction or manual change mid-run, corrupting a budget that
    ///     must only ever measure elapsed time. Tests substitute a manually-
    ///     advanced fake clock so a wave's simulated duration is an exact,
    ///     deterministic quantity instead of `Task.sleep`'s real elapsed
    ///     time, which CPU contention from unrelated concurrently-running
    ///     tests can inflate past a budget boundary the test never intended
    ///     to cross.
    public init(
        plan: MutationPlan,
        configuration: Configuration,
        projectRoot: URL,
        build: any BuildAdapter,
        test: any TestAdapter,
        workspaces: WorkspaceManager,
        checkpoints: CheckpointStore? = nil,
        artifactsRoot: URL? = nil,
        toolchain: ToolchainFingerprint? = nil,
        coverageCache: CoverageProfileCache? = nil,
        coverageCacheKey: CoverageProfileCache.Key? = nil,
        resultCache: MutationResultCache? = nil,
        resultCacheDigest: String? = nil,
        priorityStore: TestPriorityStore? = nil,
        progress: MutationProgressReporter? = nil,
        preEstablishedBaseline: SharedBaselineEstablisher.Outcome? = nil,
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        }
    ) {
        self.plan = plan
        self.configuration = configuration
        self.projectRoot = projectRoot
        self.build = build
        self.test = test
        self.workspaces = workspaces
        self.checkpoints = checkpoints
        self.artifactsRoot = artifactsRoot
        self.toolchain = toolchain ?? plan.toolchain
        self.coverageCache = coverageCache
        self.coverageCacheKey = coverageCacheKey
        self.resultCache = resultCache
        self.resultCacheDigest = resultCacheDigest
        self.priorityStore = priorityStore
        self.progress = progress
        self.preEstablishedBaseline = preEstablishedBaseline
        self.monotonicNow = monotonicNow
        self.confirmationCoordinator = MutationConfirmationCoordinator(
            workspaces: workspaces, build: build, test: test, configuration: configuration, projectRoot: projectRoot
        )
        self.evidenceAssembler = MutationEvidenceAssembler(
            plan: plan,
            configuration: configuration,
            checkpoints: checkpoints,
            artifactsRoot: artifactsRoot,
            resultCache: resultCache,
            resultCacheDigest: resultCacheDigest,
            progress: progress,
            operationalIssues: operationalIssues
        )
    }

    // MARK: - Run

    public func run() async throws -> RunReport {
        let startedAt = Date()

        let baseline: BaselineContext
        switch await establishBaseline() {
        case let .failed(record, diagnosis):
            return failClosedReport(startedAt: startedAt, baseline: record, diagnosis: diagnosis)
        case let .established(context):
            baseline = context
        }

        // Checkpoint hits first: same-run resume is always-trusted, so it
        // takes priority over the cross-run cache. A mutant already
        // recorded in a checkpoint is removed from the pool the cache is
        // consulted against, so the two stores cannot double-count.
        let resumed = ((try await checkpoints?.loadAll(plan: plan)) ?? []).map { $0.markedAsCheckpointResume() }
        let checkpointedIDs = Set(resumed.map(\.id))

        // Cross-run result cache: a mutant whose MutationID was evaluated
        // against an identical execution context (same source, tests,
        // toolchain, configuration) is reused without rebuilding or
        // retesting. The cache stores only reportable, integrity-safe
        // verdicts — infrastructure failures and other environmental state
        // are never cached (see `MutationResultCache.store`).
        var cacheHits: [MutationResult] = []
        var pending: [MutationPoint] = []
        for point in plan.mutations where !checkpointedIDs.contains(point.id) {
            if let digest = resultCacheDigest,
               let cached = await resultCache?.load(
                   MutationResultCache.Key(mutationID: point.id, contextDigest: digest),
                   point: point, planID: plan.planID, workUnitID: plan.workUnitID
               ) {
                cacheHits.append(cached)
            } else {
                pending.append(point)
            }
        }

        var results = resumed + cacheHits
        // Every freshly-evaluated mutant's own `finalize` call already wrote
        // it to the checkpoint and (when cacheable) the cross-run cache,
        // right next to the raw `MutationObservations` that produced it —
        // no separate store pass is needed here (ADR-0006 Stage 1, second
        // review round: `finalize`'s own doc comment explains why the write
        // moved there).
        let (evaluated, batchExecution) = try await evaluate(pending, baseline: baseline)

        results.append(contentsOf: evaluated)
        results.sort { $0.id < $1.id }

        // ADR-0006 Stage 1: the ledger, not the plain array, is this run's
        // authoritative result state — `results` above is retired to a
        // display-ordering convenience the moment every result has been
        // gathered. A duplicate insert here (the identical `MutationID`
        // reaching both a checkpoint/cache hit and a freshly-evaluated
        // result, say) is a real bug this construction surfaces
        // immediately, not a `Set`-based count mismatch `IntegrityChecker`
        // would have had to notice after the fact.
        var ledger = ResultLedger<MutationResult>()
        for result in results {
            try ledger.insert(result)
        }

        return RunReport(
            planID: plan.planID,
            startedAt: startedAt,
            finishedAt: Date(),
            projectRoot: projectRoot.path,
            toolchain: toolchain,
            baseline: baseline.record,
            ledger: ledger,
            integrity: IntegrityChecker.check(plan: plan, ledger: ledger, baselinePassed: true),
            batchExecution: batchExecution,
            operationalIssues: await operationalIssues.snapshot()
        )
    }

    /// Runs the pending mutations, at most `resolvedWorkerCount()` at a time.
    private func evaluate(
        _ pending: [MutationPoint], baseline: BaselineContext
    ) async throws -> (results: [MutationResult], batchExecution: BatchExecutionSummary?) {
        if let batchSize = configuration.execution.testBatchSize, batchSize > 0,
           test is any BatchTestable {
            if configuration.execution.incrementalBuild {
                // Wave-based early kill (`testInWaves`, dispatched from
                // `testAndFinish`) has no pipelined equivalent: it tests one
                // mutant's ONE next prioritised test per wave and carries
                // survivors forward across rounds, which has no
                // correspondence in the pipelined test lane's model of "a
                // clone arrives once, is tested once, is done." Routing a
                // wave-mode configuration through pipelining would silently
                // disable early abort — every mutant would run its whole
                // selected-test list, and priority history would never be
                // read or updated — so it keeps using the sequential
                // (non-pipelined) build-then-test path instead, which still
                // reaches `testAndFinish` and therefore `testInWaves`. Only
                // when wave mode is NOT requested does pipelining apply.
                if configuration.execution.earlyAbortSelectedTests, priorityStore != nil {
                    return try await evaluateIncrementallyInBatchesSequential(pending, baseline: baseline, batchSize: batchSize)
                }
                return try await evaluateIncrementallyInBatches(pending, baseline: baseline, batchSize: batchSize)
            }
            return try await evaluateInBatches(pending, baseline: baseline, batchSize: batchSize)
        }

        if configuration.execution.incrementalBuild {
            return (try await evaluateIncrementally(pending, baseline: baseline), nil)
        }

        let workers = max(1, configuration.execution.resolvedWorkerCount())
        var collected: [MutationResult] = []

        try await withThrowingTaskGroup(of: MutationResult.self) { group in
            var remaining = pending.makeIterator()

            for _ in 0 ..< workers {
                guard let point = remaining.next() else { break }
                group.addTask { await evaluate(point, baseline: baseline) }
            }

            // One in, one out: builds are the most expensive thing this tool
            // does and running more of them than the machine has workers for
            // buys contention, not throughput.
            while let result = try await group.next() {
                collected.append(result)
                if let point = remaining.next() {
                    group.addTask { await evaluate(point, baseline: baseline) }
                }
            }
        }

        return (collected, nil)
    }

    /// `evaluate(_:baseline:)`'s counterpart for
    /// `Configuration.execution.incrementalBuild`: `resolvedWorkerCount()`
    /// persistent sandboxes, each pulling mutants from a shared queue and
    /// evaluating them one at a time, reverting the one file it touched
    /// before moving to the next — see `runIncrementalWorker`.
    ///
    /// The per-mutant evaluation itself (`evaluate(_:in:baseline:startedAt:)`)
    /// is unchanged and shared with the non-incremental path: everything
    /// about *what* proves a verdict — activation hash against baseline,
    /// crash/timeout confirmation in their own fresh sandboxes — stays
    /// exactly as it is there. Only *which* sandbox a mutant's own first
    /// build and test run in changes.
    private func evaluateIncrementally(_ pending: [MutationPoint], baseline: BaselineContext) async throws -> [MutationResult] {
        let workers = max(1, configuration.execution.resolvedWorkerCount())
        let queue = MutationQueue(pending)

        return try await withThrowingTaskGroup(of: [MutationResult].self) { group in
            for workerIndex in 0 ..< workers {
                group.addTask {
                    await runIncrementalWorker(id: "incr-worker-\(workerIndex)", queue: queue, baseline: baseline)
                }
            }

            var collected: [MutationResult] = []
            for try await workerResults in group {
                collected.append(contentsOf: workerResults)
            }
            return collected
        }
    }

    /// One persistent sandbox's lifetime: created once, handed every mutant
    /// this worker dequeues in turn, reverted to pristine after each one,
    /// destroyed once the queue is empty.
    ///
    /// A worker that cannot even create its sandbox does not silently drop
    /// its share of the plan: it drains the queue reporting
    /// `.infrastructureFailure` for each mutant it would have taken, the
    /// same fate a per-mutant sandbox failure has on the non-incremental
    /// path, so every planned mutation still owes the integrity check a
    /// result.
    ///
    /// F3 verdict-contamination audit: this sandbox's deliberate reuse
    /// across mutations is an accepted, *unproven*, not proven-safe risk
    /// — see `ProcessSupervisor`'s own "Remaining risks" doc comment for
    /// the full reasoning and the exact reopening trigger. No production
    /// mitigation here on purpose.
    private func runIncrementalWorker(
        id: String, queue: MutationQueue, baseline: BaselineContext
    ) async -> [MutationResult] {
        var results: [MutationResult] = []

        let sandbox: URL
        do {
            sandbox = try await workspaces.createSandbox(id: id)
        } catch {
            while let point = await queue.next() {
                let result = await evidenceAssembler.infrastructureFailureResult(
                    point: point,
                    diagnosis: "No persistent incremental-build sandbox could be created for this worker: \(error)",
                    durationSeconds: 0
                )
                results.append(result)
            }
            return results
        }

        while let point = await queue.next(forWorker: id) {
            let started = Date()
            let result = await evaluate(point, in: sandbox, baseline: baseline, startedAt: started)
            // Always attempted, regardless of how the mutant's own
            // evaluation went: the next mutant on this worker must start
            // from a pristine file no matter what happened to this one — a
            // build failure, a crash, an anchor rejection that never wrote
            // anything. `restoreFile` re-clones from `projectRoot`, which
            // is read-only and untouched, so this can only ever put the
            // sandbox back to a known-good state, never compound an error.
            try? await workspaces.restoreFile(relativePath: point.file, in: sandbox)
            results.append(result)
        }

        try? await workspaces.destroySandbox(at: sandbox)
        return results
    }

    /// `evaluate(_:baseline:)`'s counterpart for `Configuration.execution
    /// .incrementalBuild` and `Configuration.execution.testBatchSize`
    /// together: `resolvedWorkerCount()` persistent sandboxes build mutants
    /// incrementally and in place, exactly like `evaluateIncrementally` —
    /// but **pipelined** with a single test lane that tests a batch the
    /// moment it fills up, instead of waiting for every worker's build
    /// queue to drain first. A prepared mutant's build is cloned out to its
    /// own independent location (see `WorkspaceManager.cloneProducts`) the
    /// moment it is ready, handed to `PipelineCoordinator`, and the worker
    /// moves straight on to its next mutant's build — the same clone-and-go
    /// shape the previous two-phase design used, except the clone is
    /// consumed concurrently rather than only after every worker finishes.
    /// This overlaps the two dominant costs of a run — Swift compilation
    /// (CPU-bound, inside the worker sandboxes) and `xcodebuild test`
    /// (simulator-bound, inside the test lane) — which the strict two-phase
    /// design left serialized: the test lane sat idle for the whole build
    /// phase, and every build worker sat idle for the whole test phase.
    ///
    /// **Sandbox lifetime, and why it needs a live reference count, not a
    /// single barrier.** A cloned products directory only carries the
    /// mutant's *build products* (see `WorkspaceManager.cloneProducts`); a
    /// test that resolves a fixture through a source-relative path baked in
    /// at compile time (an ordinary, idiomatic pattern: `URL(fileURLWithPath:
    /// #filePath)` walked up to the project root) still resolves against the
    /// worker sandbox the source was compiled in, not the clone — so a
    /// worker's own sandbox must outlive every clone it produced, not just
    /// its own build loop (this is the same fact `PipelineCoordinator`'s doc
    /// comment, and the non-pipelined fix this generalizes, explain in more
    /// detail). With build and test now running concurrently instead of in
    /// two strict phases, there is no single point in time — no "every
    /// build is done" barrier — after which it is safe to destroy every
    /// worker's sandbox: a fast worker can finish its whole build queue
    /// while its own most recent clones are still sitting in the test
    /// lane's forming batch, not yet tested. `PipelineCoordinator` tracks,
    /// per worker, an outstanding-clone count (incremented the instant a
    /// clone is handed to the coordinator, decremented the instant the test
    /// lane finishes testing it — success, failure, or infrastructure
    /// error, every path decrements) and destroys that worker's sandbox
    /// exactly when its build loop has ended *and* its outstanding count has
    /// reached zero, whichever of those two events happens last, for that
    /// worker specifically. See `PipelineCoordinator` below for the actor
    /// that makes both halves of that check atomic.
    private func evaluateIncrementallyInBatches(
        _ pending: [MutationPoint], baseline: BaselineContext, batchSize: Int
    ) async throws -> (results: [MutationResult], batchExecution: BatchExecutionSummary?) {
        let workers = max(1, configuration.execution.resolvedWorkerCount())
        let queue = MutationQueue(pending)
        let collector = PipelineCollector()
        let coordinator = PipelineCoordinator(workspaces: workspaces, workerCount: workers)

        // The test lane and the build workers are siblings in one task
        // group, not nested — nesting the build workers inside the lane (or
        // vice versa) would make one wait structurally for the other to be
        // spawned/joined, which is exactly the coupling pipelining exists to
        // remove. They coordinate only through `coordinator`: build workers
        // call `send`/`workerBuildFinished`, the test lane calls `receive`,
        // and `receive` returns `nil` on its own once every worker has
        // finished and every buffered clone has been drained — no outer
        // "finish" signal needs to be sent from here.
        // Neither side ever throws (see `runPipelinedBuildWorker`'s and
        // `runPipelinedTestLane`'s doc comments: both are fail-closed —
        // every failure becomes an `.infrastructureFailure` result rather
        // than a thrown error), so a plain, non-throwing task group is
        // enough; `evaluateIncrementallyInBatches` stays `throws` only for
        // signature parity with its sibling evaluation paths.
        await withTaskGroup(of: Void.self) { outer in
            outer.addTask { [self] in
                await runPipelinedTestLane(
                    coordinator: coordinator, collector: collector, baseline: baseline, batchSize: batchSize
                )
            }
            outer.addTask { [self] in
                await withTaskGroup(of: Void.self) { buildGroup in
                    for workerIndex in 0 ..< workers {
                        buildGroup.addTask {
                            await self.runPipelinedBuildWorker(
                                id: "incr-worker-\(workerIndex)", queue: queue, baseline: baseline,
                                collector: collector, coordinator: coordinator
                            )
                        }
                    }
                }
            }
            await outer.waitForAll()
        }

        let snapshot = await collector.snapshot()
        return (snapshot.results, snapshot.summary)
    }

    /// The pre-pipelining incremental-plus-batching path, kept only for
    /// wave-based early kill (see `evaluate(_:baseline:)`'s dispatch):
    /// build every mutant first (bounded by `resolvedWorkerCount()`), THEN
    /// test the ones that need it, through `testAndFinish` — which is what
    /// gives `testInWaves` a chance to dispatch at all. The pipelined
    /// `evaluateIncrementallyInBatches` above interleaves building and
    /// testing instead, which is strictly faster but has no way to run
    /// wave-based early kill's multi-round, one-test-per-wave protocol.
    private func evaluateIncrementallyInBatchesSequential(
        _ pending: [MutationPoint], baseline: BaselineContext, batchSize: Int
    ) async throws -> (results: [MutationResult], batchExecution: BatchExecutionSummary?) {
        let workers = max(1, configuration.execution.resolvedWorkerCount())
        let queue = MutationQueue(pending)

        var collected: [MutationResult] = []
        var readyToTest: [PreparedMutant] = []
        var workerSandboxes: [URL] = []

        try await withThrowingTaskGroup(
            of: (results: [MutationResult], readyToTest: [PreparedMutant], sandbox: URL?).self
        ) { group in
            for workerIndex in 0 ..< workers {
                group.addTask {
                    await self.runIncrementalBuildWorkerSequential(
                        id: "incr-worker-\(workerIndex)", queue: queue, baseline: baseline
                    )
                }
            }

            for try await worker in group {
                collected.append(contentsOf: worker.results)
                readyToTest.append(contentsOf: worker.readyToTest)
                if let sandbox = worker.sandbox {
                    workerSandboxes.append(sandbox)
                }
            }
        }

        let (testResults, summary) = try await testAndFinish(readyToTest: readyToTest, baseline: baseline, batchSize: batchSize)
        collected.append(contentsOf: testResults)

        // Only now — every clone any worker produced has been tested and
        // its own result recorded — is it safe to tear down the sandboxes
        // that built them.
        for sandbox in workerSandboxes {
            try? await workspaces.destroySandbox(at: sandbox)
        }

        return (collected, summary)
    }

    /// One persistent sandbox's lifetime for
    /// `evaluateIncrementallyInBatchesSequential`: same build shape as
    /// `runIncrementalWorker`, but calls only `prepare(...)` per mutant
    /// (never tests in place), clones a `.readyToTest` mutant's artifact out
    /// before moving on instead of holding the worker's own sandbox open
    /// until it is tested, and returns its own sandbox to the caller instead
    /// of destroying it — the caller destroys it once every clone this
    /// worker produced has actually been tested by the shared `testAndFinish`
    /// barrier.
    ///
    /// A worker that cannot even create its sandbox fails exactly like
    /// `runIncrementalWorker`'s does: it drains the queue reporting
    /// `.infrastructureFailure` for every mutant it would have taken, rather
    /// than silently dropping its share of the plan. It returns `sandbox:
    /// nil` in that case — there is nothing for the caller to keep alive or
    /// destroy.
    ///
    /// Same accepted, unproven cross-mutant reuse risk as
    /// `runIncrementalWorker` — see that method's own doc comment and
    /// `ProcessSupervisor`'s "Remaining risks" section.
    private func runIncrementalBuildWorkerSequential(
        id: String, queue: MutationQueue, baseline: BaselineContext
    ) async -> (results: [MutationResult], readyToTest: [PreparedMutant], sandbox: URL?) {
        var results: [MutationResult] = []
        var readyToTest: [PreparedMutant] = []

        let sandbox: URL
        do {
            sandbox = try await workspaces.createSandbox(id: id)
        } catch {
            while let point = await queue.next() {
                let result = await evidenceAssembler.infrastructureFailureResult(
                    point: point,
                    diagnosis: "No persistent incremental-build sandbox could be created for this worker: \(error)",
                    durationSeconds: 0
                )
                results.append(result)
            }
            return (results, readyToTest, nil)
        }

        while let point = await queue.next(forWorker: id) {
            let started = Date()
            switch await prepare(point, in: sandbox, baseline: baseline, startedAt: started) {
            case let .finished(result):
                results.append(result)
            case let .readyToTest(prepared):
                do {
                    let clone = try await workspaces.cloneProducts(
                        from: prepared.artifact.productsDirectory, id: point.id.rawValue
                    )
                    readyToTest.append(Self.relocating(prepared, to: clone))
                } catch {
                    let result = await evidenceAssembler.infrastructureFailureResult(
                        point: point,
                        diagnosis: "This mutant's build could not be cloned out for batched testing: \(error)",
                        evidence: evidenceAssembler.evidence(
                            prepared.applied, artifact: prepared.artifact, activation: prepared.activation
                        ),
                        durationSeconds: Date().timeIntervalSince(started)
                    )
                    results.append(result)
                }
            }
            // Always attempted, same reasoning as `runIncrementalWorker`: the
            // next mutant on this worker must start from a pristine file
            // regardless of how this one went — and by this point this
            // mutant's build artifact, if it produced one, has already
            // either been cloned out or given up on, so nothing here still
            // depends on the sandbox's current contents.
            try? await workspaces.restoreFile(relativePath: point.file, in: sandbox)
        }

        return (results, readyToTest, sandbox)
    }

    /// One persistent sandbox's lifetime for the pipelined
    /// incremental-plus-batching path: same build shape as
    /// `runIncrementalWorker`, but calls only `prepare(...)` per mutant
    /// (never tests in place), and instead of collecting `.readyToTest`
    /// mutants into a return value, clones each one out and immediately
    /// hands it to `coordinator.send`, which both queues it for the test
    /// lane and records it against this worker's outstanding-clone count.
    /// A result that finishes during the build itself (`.noCoverage`, a
    /// build failure, a clone failure) goes straight to `collector` — it
    /// never touches the coordinator's count, because it never produced a
    /// clone for the test lane to owe a decrement for.
    ///
    /// A worker that cannot even create its sandbox fails exactly like
    /// `runIncrementalWorker`'s does: it drains the queue reporting
    /// `.infrastructureFailure` for every mutant it would have taken,
    /// rather than silently dropping its share of the plan. Either way,
    /// `coordinator.registerWorker` and `coordinator.workerBuildFinished`
    /// are called on every exit path — including this one — because the
    /// test lane's `receive` loop only ends once every worker has reported
    /// itself finished; a worker that returned early without reporting in
    /// would leave the test lane, and the whole pipeline, waiting forever.
    ///
    /// Same accepted, unproven cross-mutant reuse risk as
    /// `runIncrementalWorker` — see that method's own doc comment and
    /// `ProcessSupervisor`'s "Remaining risks" section.
    private func runPipelinedBuildWorker(
        id: String, queue: MutationQueue, baseline: BaselineContext,
        collector: PipelineCollector, coordinator: PipelineCoordinator
    ) async {
        let sandbox: URL
        do {
            sandbox = try await workspaces.createSandbox(id: id)
        } catch {
            await coordinator.registerWorker(id, sandbox: nil)
            while let point = await queue.next() {
                let result = await evidenceAssembler.infrastructureFailureResult(
                    point: point,
                    diagnosis: "No persistent incremental-build sandbox could be created for this worker: \(error)",
                    durationSeconds: 0
                )
                await collector.add(result)
            }
            await coordinator.workerBuildFinished(id)
            return
        }

        await coordinator.registerWorker(id, sandbox: sandbox)

        while let point = await queue.next(forWorker: id) {
            let started = Date()
            switch await prepare(point, in: sandbox, baseline: baseline, startedAt: started) {
            case let .finished(result):
                await collector.add(result)
            case let .readyToTest(prepared):
                do {
                    let clone = try await workspaces.cloneProducts(
                        from: prepared.artifact.productsDirectory, id: point.id.rawValue
                    )
                    await coordinator.send(Self.relocating(prepared, to: clone), workerID: id)
                } catch {
                    let result = await evidenceAssembler.infrastructureFailureResult(
                        point: point,
                        diagnosis: "This mutant's build could not be cloned out for batched testing: \(error)",
                        evidence: evidenceAssembler.evidence(
                            prepared.applied, artifact: prepared.artifact, activation: prepared.activation
                        ),
                        durationSeconds: Date().timeIntervalSince(started)
                    )
                    await collector.add(result)
                }
            }
            // Always attempted, same reasoning as `runIncrementalWorker`: the
            // next mutant on this worker must start from a pristine file
            // regardless of how this one went — and by this point this
            // mutant's build artifact, if it produced one, has already
            // either been handed to the coordinator or given up on, so
            // nothing here still depends on the sandbox's current contents.
            try? await workspaces.restoreFile(relativePath: point.file, in: sandbox)
        }

        // Not a destroy call: this worker's build loop is done, but clones
        // it produced may still be sitting in the test lane's forming batch
        // or mid-test right now. `workerBuildFinished` only destroys the
        // sandbox if the outstanding-clone count is already zero — see
        // `PipelineCoordinator`.
        await coordinator.workerBuildFinished(id)
    }

    /// The test lane's whole lifetime for the pipelined incremental-plus-
    /// batching path: pulls clones from `coordinator.receive()` as they
    /// arrive from every build worker, accumulates them into a batch, and
    /// tests a batch the moment it reaches `batchSize` — not waiting for
    /// every worker to finish first. `receive()` returns `nil` on its own
    /// once every worker has reported itself finished and every buffered
    /// clone has been drained, which is this loop's only exit condition; a
    /// final partial batch (fewer than `batchSize` clones, however many
    /// were left when the last worker finished) is still flushed after the
    /// loop ends, same as the non-pipelined path's last chunk.
    ///
    /// Runs as a single task: there is exactly one test lane regardless of
    /// worker count, so `batchIndex` (used only for the batch sandbox's
    /// name) is a plain local counter, not a shared actor — nothing else
    /// touches it concurrently.
    private func runPipelinedTestLane(
        coordinator: PipelineCoordinator, collector: PipelineCollector,
        baseline: BaselineContext, batchSize: Int
    ) async {
        // `evaluate(_:baseline:)` only dispatches here when `test is any
        // BatchTestable` already held true, so this cannot actually fail —
        // but the fallback below costs nothing, and unlike
        // `testAndFinish`'s equivalent fallback it MUST keep draining and
        // reporting into the coordinator: a build worker's `send` is only
        // balanced by a matching `finishedTesting`, and this lane is the
        // only place that call is made. Abandoning the drain here would
        // leave every worker's outstanding count stuck above zero forever,
        // and their sandboxes never destroyed.
        guard let batchable = test as? any BatchTestable else {
            while let next = await coordinator.receive() {
                let result = await finishAfterTest(
                    next.item, baseline: baseline,
                    run: TestRunResult(
                        status: .infrastructureFailure, summary: nil, command: next.item.artifact.command,
                        resultArtifactPath: nil,
                        diagnosis: "The batch test adapter no longer conforms to BatchTestable."
                    )
                )
                try? await workspaces.destroySandbox(at: next.item.sandbox)
                await collector.add(result)
                await coordinator.finishedTesting(workerID: next.workerID)
            }
            return
        }

        var batch: [PreparedMutant] = []
        var batchOwners: [MutationID: String] = [:]
        var batchIndex = 0

        func flush() async {
            guard !batch.isEmpty else { return }
            let (results, configurations, duration) = await testOneBatch(
                batch, batchIndex: batchIndex, baseline: baseline, batchable: batchable
            )
            batchIndex += 1
            await collector.addAll(results)
            await collector.recordBatch(configurations: configurations, duration: duration)
            // Every result `testOneBatch` produced owes exactly one
            // decrement to the worker whose build produced its clone —
            // looked up by mutation ID (not by array position) so this
            // stays correct regardless of any future reordering inside
            // `testOneBatch`.
            for result in results {
                if let workerID = batchOwners[result.point.id] {
                    await coordinator.finishedTesting(workerID: workerID)
                }
            }
            batch.removeAll(keepingCapacity: true)
            batchOwners.removeAll(keepingCapacity: true)
        }

        while let next = await coordinator.receive() {
            // An unattributed mutant (no covering-test attribution) runs its
            // own full configured test list — bundling it into a shared
            // batch, with narrowly-attributed mutants or with another
            // unattributed mutant, would let its cost multiply rather than
            // share: the same bug `Self.chunked` exists to prevent on the
            // non-pipelined path (see its doc comment). Tested alone,
            // immediately, rather than accumulated into `batch` — nothing is
            // gained by waiting for `batchSize` here, since this mutant
            // never shares an invocation with anything else regardless.
            guard next.item.selectedTests != nil else {
                let (results, configurations, duration) = await testOneBatch(
                    [next.item], batchIndex: batchIndex, baseline: baseline, batchable: batchable
                )
                batchIndex += 1
                await collector.addAll(results)
                await collector.recordBatch(configurations: configurations, duration: duration)
                await coordinator.finishedTesting(workerID: next.workerID)
                continue
            }
            batch.append(next.item)
            batchOwners[next.item.point.id] = next.workerID
            if batch.count >= batchSize {
                await flush()
            }
        }
        await flush()
    }

    /// Rebuilds a `PreparedMutant` to point at a cloned products directory
    /// instead of the (still-alive, about-to-be-rebuilt) sandbox that built
    /// it. `productHash`/`command` describe the build itself, not where it
    /// happens to be stored, so they carry over unchanged — only the paths
    /// move. Reassigning `sandbox` alongside `artifact` (never one without
    /// the other) is what keeps `MutationConfirmationCoordinator.confirmKill`'s
    /// same-sandbox retest testing the actual mutant it is confirming,
    /// rather than whatever the worker has since rebuilt.
    ///
    /// Phase A1 extraction: `internal` (not `private`), because
    /// `MutationConfirmationCoordinator.confirmKillIfNeeded`, in its own
    /// file, calls this too — see that method's own doc comment.
    static func relocating(_ prepared: PreparedMutant, to clone: URL) -> PreparedMutant {
        let artifact = BuildArtifact(
            productsDirectory: clone,
            productHash: prepared.artifact.productHash,
            xctestrunPath: prepared.artifact.xctestrunPath.map { clone.appendingPathComponent($0.lastPathComponent) },
            command: prepared.artifact.command
        )
        return PreparedMutant(
            point: prepared.point,
            sandbox: clone,
            applied: prepared.applied,
            artifact: artifact,
            activation: prepared.activation,
            observation: prepared.observation,
            selectedTests: prepared.selectedTests,
            startedAt: prepared.startedAt,
            buildDurationSeconds: prepared.buildDurationSeconds,
            // Untouched by this relocation: `confirmationSandbox` is its own,
            // separately established independent clone (see that field's own
            // doc comment) — relocating *this* mutant's primary-test home
            // (the whole point of this function, for a persistent worker's
            // own sandbox) has nothing to do with where its confirmation
            // retest, if any, already lives.
            confirmationSandbox: prepared.confirmationSandbox
        )
    }

    /// `evaluate(_:baseline:)`'s counterpart for
    /// `Configuration.execution.testBatchSize`: builds every mutant the
    /// ordinary, isolated way — its own fresh sandbox, its own build, its
    /// own activation hash — then tests up to `batchSize` of them per
    /// `xcodebuild` invocation instead of one invocation per mutant.
    ///
    /// Two phases, not interleaved: every mutant is built first (bounded by
    /// `resolvedWorkerCount()`, same parallelism the unbatched path uses),
    /// then the ones that need testing are grouped and tested in batches.
    /// A mutant whose build alone already produced a verdict — an anchor
    /// that no longer matches, `.noCoverage`, a build failure — never
    /// reaches the test phase at all, exactly as it never would on the
    /// unbatched path. `finishAfterTest` and every confirmation path are
    /// shared unchanged with `evaluate(_:in:baseline:startedAt:)`: a
    /// batched mutant's crash or timeout confirmation still gets its own
    /// fresh, independent, unbatched sandbox.
    private func evaluateInBatches(
        _ pending: [MutationPoint], baseline: BaselineContext, batchSize: Int
    ) async throws -> (results: [MutationResult], batchExecution: BatchExecutionSummary?) {
        var collected: [MutationResult] = []
        var readyToTest: [PreparedMutant] = []

        let workers = max(1, configuration.execution.resolvedWorkerCount())
        try await withThrowingTaskGroup(of: (URL, PrepareOutcome).self) { group in
            var remaining = pending.makeIterator()

            func addTask(for point: MutationPoint) throws {
                group.addTask {
                    let started = Date()
                    let sandbox: URL
                    do {
                        sandbox = try await self.workspaces.createSandbox(id: point.id.rawValue)
                    } catch {
                        return (
                            URL(fileURLWithPath: "/"),
                            .finished(await self.evidenceAssembler.infrastructureFailureResult(
                                point: point,
                                diagnosis: "No sandbox could be created for this mutant: \(error)",
                                durationSeconds: Date().timeIntervalSince(started)
                            ))
                        )
                    }
                    let outcome = await self.prepare(point, in: sandbox, baseline: baseline, startedAt: started)
                    return (sandbox, outcome)
                }
            }

            for _ in 0 ..< workers {
                guard let point = remaining.next() else { break }
                try addTask(for: point)
            }

            while let (sandbox, outcome) = try await group.next() {
                switch outcome {
                case let .finished(result):
                    try? await workspaces.destroySandbox(at: sandbox)
                    collected.append(result)
                case let .readyToTest(prepared):
                    readyToTest.append(prepared)
                }
                if let point = remaining.next() {
                    try addTask(for: point)
                }
            }
        }

        let (testResults, summary) = try await testAndFinish(readyToTest: readyToTest, baseline: baseline, batchSize: batchSize)
        collected.append(contentsOf: testResults)
        return (collected, summary)
    }

    /// Groups `readyToTest` into the chunks `testAndFinish` will each hand to
    /// one `runBatch` call.
    ///
    /// A mutant with no attributed covering test (`selectedTests == nil`)
    /// runs the full configured test list, not a narrow one — batching
    /// exists to amortize one xcodebuild invocation's fixed overhead across
    /// many *small* runs, and several full-suite mutants sharing a batch
    /// does the opposite: their costs simply add, multiplying rather than
    /// sharing. A batch composed this way can exceed even `batchTimeout`'s
    /// generous per-mutant-count sizing, which then makes every mutant in
    /// it — including perfectly good, fast, narrowly-attributed ones that
    /// happened to land in the same batch — unprovable and `.flaky`, not
    /// because anything about them individually is unstable.
    ///
    /// Chunked separately, at size 1: this costs nothing relative to running
    /// them outside batching at all (there was no sharable overhead to
    /// lose), and keeps them from inflating a shared batch's cumulative test
    /// time past its budget.
    private static func chunked(_ readyToTest: [PreparedMutant], batchSize: Int) -> [[PreparedMutant]] {
        let narrow = readyToTest.filter { $0.selectedTests != nil }
        let unrestricted = readyToTest.filter { $0.selectedTests == nil }
        return stride(from: 0, to: narrow.count, by: batchSize)
            .map { Array(narrow[$0 ..< min($0 + batchSize, narrow.count)]) }
            + unrestricted.map { [$0] }
    }

    /// The test phase shared by every path that builds a batch of mutants
    /// ahead of testing them: batches `readyToTest` and tests each batch in
    /// one `xcodebuild` invocation, then classifies and destroys each
    /// mutant's own sandbox plus the batch sandbox once its results are in
    /// hand.
    ///
    /// Deliberately agnostic to *how* `prepared.sandbox` came to hold its
    /// artifact — `evaluateInBatches` hands it a mutant's own fresh,
    /// isolated sandbox; `evaluateIncrementallyInBatches` hands it a cloned
    /// products directory, independent of the persistent worker sandbox
    /// that built it (see `WorkspaceManager.cloneProducts`). Both are just
    /// "a directory to test from and destroy afterward" as far as this
    /// function is concerned, which is what makes sharing it safe.
    private func testAndFinish(
        readyToTest: [PreparedMutant], baseline: BaselineContext, batchSize: Int
    ) async throws -> (results: [MutationResult], batchExecution: BatchExecutionSummary) {
        // Wave-based early kill: when a priority store is available and
        // early abort is requested, test one prioritised covering test per
        // mutant per wave instead of a mutant's whole selection in one
        // batch. Killed mutants stop immediately; survivors advance to
        // their next test in the next wave. Each wave is still one batched
        // `xcodebuild` invocation, not one per test — this is the fix for
        // `PrioritizingTestAdapter`'s per-test-per-mutant fixed cost, not a
        // parallel test-running mechanism: it hands its batches to the same
        // `batchable.runBatch` (and therefore the same, already-fixed batch
        // attribution path) every other batched path here uses.
        if configuration.execution.earlyAbortSelectedTests,
           let store = priorityStore,
           let batchable = test as? any BatchTestable,
           !readyToTest.isEmpty {
            return await testInWaves(
                readyToTest: readyToTest, baseline: baseline, store: store, batchable: batchable, batchSize: batchSize
            )
        }

        var collected: [MutationResult] = []

        guard let batchable = test as? any BatchTestable, !readyToTest.isEmpty else {
            // Nothing built successfully, or the adapter stopped conforming
            // between the dispatch check and here (it cannot, but the
            // fallback costs nothing): destroy any leftover sandboxes and
            // fall back to testing them one at a time rather than losing them.
            // This is NOT genuine batching, so it does not contribute to the
            // batch execution summary.
            for prepared in readyToTest {
                let testStarted = Date()
                let run = try? await confirmationCoordinator.runMutantTests(
                    prepared.point, artifact: prepared.artifact, in: prepared.sandbox,
                    timeoutSeconds: baseline.timeouts.mutantLimitSeconds(selectedTests: prepared.selectedTests),
                    selectedTests: prepared.selectedTests
                )
                let testDurationSeconds = Date().timeIntervalSince(testStarted)
                let result = await finishAfterTest(
                    prepared, baseline: baseline,
                    run: run ?? TestRunResult(
                        status: .infrastructureFailure, summary: nil, command: prepared.artifact.command,
                        resultArtifactPath: nil, diagnosis: "The mutant's tests could not be run."
                    ),
                    testDurationSeconds: testDurationSeconds
                )
                try? await workspaces.destroySandbox(at: prepared.sandbox)
                collected.append(result)
            }
            return (collected, BatchExecutionSummary(batchCount: 0, totalConfigurations: 0))
        }

        var batchCount = 0
        var totalConfigurations = 0
        var batchDurations: [Double] = []

        // `Self.chunked` (not a plain stride slice): keeps unattributed
        // mutants out of a shared batch with each other — see its doc
        // comment — while `testOneBatch` (shared with the pipelined test
        // lane, see `runPipelinedTestLane`) does the actual per-chunk
        // sandbox/build/test/classify work.
        for chunk in Self.chunked(readyToTest, batchSize: batchSize) {
            let (results, configurations, duration) = await testOneBatch(
                chunk, batchIndex: batchCount, baseline: baseline, batchable: batchable
            )
            collected.append(contentsOf: results)
            batchCount += 1
            totalConfigurations += configurations
            if let duration { batchDurations.append(duration) }
        }

        return (
            collected,
            BatchExecutionSummary(
                batchCount: batchCount, totalConfigurations: totalConfigurations, batchDurations: batchDurations
            )
        )
    }

    /// Tests every unattributed mutant's full configured test list, one per
    /// chunk — never several bundled into the same batch.
    ///
    /// Bundling more than one into a shared batch was tried first and found
    /// wrong the same way `testAndFinish`'s equivalent fix was: several
    /// full-suite reruns bundled together simply add their costs rather than
    /// sharing them, which can exceed even a batch sized generously per
    /// mutant count and mark every mutant in it — not just the slow one —
    /// unprovable. One mutant per chunk costs nothing relative to not
    /// batching them at all, since there was no sharable overhead to lose.
    private func testUnattributed(
        _ unattributed: [PreparedMutant], baseline: BaselineContext, batchable: any BatchTestable
    ) async -> (results: [MutationResult], batchCount: Int, batchDurations: [Double]) {
        var results: [MutationResult] = []
        var batchDurations: [Double] = []
        for prepared in unattributed {
            do {
                let batchSandbox = try await workspaces.createSandbox(id: "wave-unattributed-\(prepared.point.id.rawValue)")
                let items = [BatchMutantItem(id: prepared.point.id, artifact: prepared.artifact, selectedTests: nil)]
                let batchTimeout = baseline.timeouts.mutantLimitSeconds
                let batchStarted = Date()
                let runs = await batchable.runBatch(items, in: batchSandbox, timeoutSeconds: batchTimeout)
                let duration = Date().timeIntervalSince(batchStarted)
                batchDurations.append(duration)

                let run = runs[prepared.point.id] ?? TestRunResult(
                    status: .infrastructureFailure, summary: nil, command: prepared.artifact.command,
                    resultArtifactPath: nil, diagnosis: "This mutant's outcome was not reported back from its batch."
                )
                let result = await finishAfterTest(prepared, baseline: baseline, run: run, testDurationSeconds: duration)
                try? await workspaces.destroySandbox(at: prepared.sandbox)
                results.append(result)
                try? await workspaces.destroySandbox(at: batchSandbox)
            } catch {
                let result = await finishAfterTest(
                    prepared, baseline: baseline,
                    run: TestRunResult(
                        status: .infrastructureFailure, summary: nil, command: prepared.artifact.command,
                        resultArtifactPath: nil, diagnosis: "No batch sandbox could be created: \(error)"
                    )
                )
                try? await workspaces.destroySandbox(at: prepared.sandbox)
                results.append(result)
            }
        }
        return (results, unattributed.count, batchDurations)
    }

    /// Wave-based early kill: the batched replacement for
    /// `PrioritizingTestAdapter`'s one-test-per-invocation strategy.
    ///
    /// Each wave creates one batch invocation where every surviving mutant
    /// runs exactly ONE covering test — the next in its priority-ordered
    /// list. Mutants whose test fails this wave are killed and stop.
    /// Mutants whose test passes advance to their next test in the next
    /// wave. A mutant that exhausts its covering tests without ever failing
    /// one is `.survived`.
    ///
    /// The fixed per-invocation cost (~30s of simulator install/launch) is
    /// paid once per wave, not once per (mutant × covering-test) pair: a run
    /// with 50 mutants and 5 covering tests each pays it 5 times (one per
    /// wave) instead of 250 times (one per test per mutant, as wrapping the
    /// adapter one test at a time would). Killed mutants also drop out of
    /// later waves, so wave 2 onward tests strictly fewer mutants than the
    /// wave before it.
    ///
    /// Mutants without covering-test attribution (coverage was not
    /// measured, or the map has nothing to say about their line) are tested
    /// with their full configured test list before the wave loop starts —
    /// each in its own chunk, never bundled together (see
    /// `testUnattributed`) — and do not participate in subsequent waves,
    /// the same safe fallback every other selected-tests path in this file
    /// uses for `selectedTests ==
    /// nil`.
    ///
    /// `readyToTest` entries reach here exactly as `testAndFinish`'s other
    /// callers hand them off — a mutant's own fresh sandbox from
    /// `evaluateInBatches`, or a cloned products directory from
    /// `evaluateIncrementallyInBatches` — so this needs no sandbox-lifetime
    /// handling of its own: the worker sandbox that built a clone is kept
    /// alive by the caller until `testAndFinish` (and therefore every wave
    /// here) has returned, exactly as it is for the non-wave batch path.
    private func testInWaves(
        readyToTest: [PreparedMutant],
        baseline: BaselineContext,
        store: TestPriorityStore,
        batchable: any BatchTestable,
        batchSize: Int
    ) async -> (results: [MutationResult], batchExecution: BatchExecutionSummary) {
        var results: [MutationResult] = []
        var batchCount = 0
        var totalConfigurations = 0
        var batchDurations: [Double] = []

        // Partition: mutants with a known, non-empty covering-test
        // selection go into the wave loop, ordered by historical kill
        // usefulness; everything else (no attribution at all) runs its
        // full test list and is done after wave 1.
        var waveSurvivors: [WaveSurvivor] = []
        var unattributed: [PreparedMutant] = []
        // Sorted by `MutationID` before partitioning, not left in whatever
        // order builds happened to finish in — wave 1's batch composition
        // (and therefore which mutants share timing ambiguity with which)
        // must be reproducible the same way `testOneWave` makes every later
        // wave's composition reproducible.
        for prepared in readyToTest.sorted(by: { $0.point.id < $1.point.id }) {
            if let tests = prepared.selectedTests, !tests.isEmpty {
                let ordered = await store.order(tests)
                waveSurvivors.append(WaveSurvivor(prepared: prepared, remainingTests: ordered))
            } else {
                unattributed.append(prepared)
            }
        }

        if !unattributed.isEmpty {
            let (unattributedResults, count, durations) = await testUnattributed(
                unattributed, baseline: baseline, batchable: batchable
            )
            results.append(contentsOf: unattributedResults)
            batchCount += count
            totalConfigurations += unattributed.count
            batchDurations.append(contentsOf: durations)
        }

        // Wave loop for attributed mutants. `waveIndex` is part of every
        // sandbox ID this wave creates (see `testOneWave`) — without it,
        // wave 2's first chunk would reuse wave 1's first chunk's sandbox ID
        // verbatim (`chunkStart` alone resets to 0 every call), and a
        // creation racing a not-yet-finished destroy of the same path fails
        // closed as an infrastructure failure instead of testing at all.
        // Caught for real on a live Xcode project: a mutant that should have
        // been `killedByAssertion` in wave 2 came back `infrastructureFailure`
        // because its chunk's sandbox ID collided with wave 1's.
        var waveIndex = 0
        while !waveSurvivors.isEmpty {
            let (waveResults, nextSurvivors, waveBatchCount, waveConfigurations, waveDurations) = await testOneWave(
                waveSurvivors, waveIndex: waveIndex, baseline: baseline, store: store, batchable: batchable, batchSize: batchSize
            )
            results.append(contentsOf: waveResults)
            batchCount += waveBatchCount
            totalConfigurations += waveConfigurations
            batchDurations.append(contentsOf: waveDurations)
            waveSurvivors = nextSurvivors
            waveIndex += 1
        }

        return (
            results,
            BatchExecutionSummary(batchCount: batchCount, totalConfigurations: totalConfigurations, batchDurations: batchDurations)
        )
    }

    private struct WaveSurvivor: Sendable {
        let prepared: PreparedMutant
        let remainingTests: [TestIdentifier]
        /// Real test time this mutant has consumed across every wave so
        /// far — never wall clock since `prepared.startedAt`, which also
        /// counts build time and time spent waiting behind every other
        /// mutant's build/chunk and would keep accumulating even while this
        /// mutant is not being tested at all.
        var cumulativeTestSeconds: Double = 0
        /// The most recent wave's real `TestRunResult` — carried forward so
        /// a mutant that later exhausts its list or expires its budget
        /// reports its actual last test command and result artifact, not a
        /// synthetic placeholder. `nil` only before this survivor's first
        /// wave has run at all.
        var lastRun: TestRunResult?
        /// Every earlier wave this survivor passed, each with its own
        /// preserved result artifact — see `TestAttemptEvidence`. Without
        /// this, only the mutant's LAST wave's evidence would survive to the
        /// final report, silently dropping every earlier wave's.
        var attempts: [TestAttemptEvidence] = []
    }

    /// One iteration of the wave loop: classifies exhausted and
    /// budget-expired survivors, then chunks whoever is left into batches of
    /// at most `batchSize` (see `MutationRunnerBatchTestingTests` and
    /// codex's review of this branch — an earlier version ignored
    /// `batchSize` entirely and put every survivor in one batch, defeating
    /// the resource bound it exists to enforce) and tests each chunk's next
    /// prioritised test.
    private func testOneWave(
        _ waveSurvivors: [WaveSurvivor],
        waveIndex: Int,
        baseline: BaselineContext,
        store: TestPriorityStore,
        batchable: any BatchTestable,
        batchSize: Int
    ) async -> (
        results: [MutationResult], nextSurvivors: [WaveSurvivor], batchCount: Int, totalConfigurations: Int,
        batchDurations: [Double]
    ) {
        var results: [MutationResult] = []

        // Survivors that have run out of covering tests without ever
        // failing one → survived. Checked at the top of every wave, not
        // just once, because a mutant can only reach this state after
        // advancing past its last test in a previous wave.
        //
        // Checked ahead of the budget-expiry filter below on purpose: a
        // mutant that finished every one of its covering tests has a
        // complete, definitive answer, even if the wave that produced it
        // pushed cumulative time slightly past the budget. The budget
        // exists to bound how long an *unresolved* mutant gets waited on,
        // not to discard a result that did resolve.
        let exhausted = waveSurvivors.filter { $0.remainingTests.isEmpty }
        for survivor in exhausted {
            // command/resultArtifactPath come from the actual last wave's
            // test run, not the build artifact — this mutant was tested,
            // repeatedly, and the evidence should point at that, not at how
            // it was built. Falls back to the build command only in the
            // unreachable-in-practice case of a survivor with no prior wave
            // at all (remainingTests starts non-empty, so exhausting it
            // requires at least one).
            let lastRun = survivor.lastRun
            // `appendCurrentAttempt` stays false: this synthetic "all waves
            // passed" run only restates the last real wave's own result,
            // which `survivor.attempts` already recorded when that wave's
            // advance branch ran — appending it again here would duplicate
            // it rather than add anything new.
            let result = await finishAfterTest(
                survivor.prepared, baseline: baseline,
                run: TestRunResult(
                    status: .passed, summary: lastRun?.summary,
                    command: lastRun?.command ?? survivor.prepared.artifact.command,
                    resultArtifactPath: lastRun?.resultArtifactPath,
                    diagnosis: "All \(survivor.prepared.selectedTests?.count ?? 0) covering test(s) passed across every wave."
                ),
                testDurationSeconds: survivor.cumulativeTestSeconds,
                priorTestAttempts: survivor.attempts
            )
            try? await workspaces.destroySandbox(at: survivor.prepared.sandbox)
            results.append(result)
        }

        // A survivor's total *test* time across every wave it has been
        // through is bounded by the same mutantLimitSeconds a single-
        // invocation test would have gotten — otherwise a mutant with many
        // covering tests could accumulate coveringTests × mutantLimitSeconds
        // of wall clock, and the setting would no longer bound what it
        // promises to. Measured against `cumulativeTestSeconds`, not wall
        // clock since `prepared.startedAt`: that also counts build time and
        // time spent waiting behind every other mutant's build/chunk, so a
        // mutant could be timed out before its first test ever ran.
        let (budgetExpired, stillAlive) = waveSurvivors
            .filter { !$0.remainingTests.isEmpty }
            .reduce(into: (expired: [WaveSurvivor](), alive: [WaveSurvivor]())) { partial, survivor in
                // Each survivor's own budget — selected-test-clamped where it
                // has a known, non-empty covering-test selection,
                // whole-suite-scaled otherwise — not one shared number every
                // survivor is measured against regardless of how narrow its
                // own selection is.
                let mutantLimitSeconds = baseline.timeouts.mutantLimitSeconds(
                    selectedTests: survivor.prepared.selectedTests
                )
                if survivor.cumulativeTestSeconds >= mutantLimitSeconds {
                    partial.expired.append(survivor)
                } else {
                    partial.alive.append(survivor)
                }
            }
        // `cumulativeTestSeconds` crossing the limit is a trigger, not a
        // verdict — it is built from fair-share division of shared batch
        // wall clock (see `testWaveChunk`), which is an estimate, never a
        // per-configuration measurement. Reaching a `.timedOut` classification
        // from that estimate alone would mean the product's headline
        // trustworthiness claim rests on a number nobody actually measured.
        // So budget exhaustion only ever earns this survivor one real,
        // standalone, individually-timed test of its whole remaining list —
        // through the same trusted unbatched path ordinary execution already
        // uses — and only *that* result decides the final classification.
        for survivor in budgetExpired {
            let (standaloneRun, standaloneDuration) = await standaloneVerify(
                survivor.prepared, selectedTests: Set(survivor.remainingTests), baseline: baseline
            )
            let result = await finishAfterTest(
                survivor.prepared, baseline: baseline, run: standaloneRun,
                testDurationSeconds: survivor.cumulativeTestSeconds + standaloneDuration,
                priorTestAttempts: survivor.attempts, appendCurrentAttempt: true
            )
            try? await workspaces.destroySandbox(at: survivor.prepared.sandbox)
            results.append(result)
        }

        guard !stillAlive.isEmpty else { return (results, [], 0, 0, []) }

        // Deterministic batch composition: which mutants land in the same
        // chunk (and therefore share timing ambiguity) must not depend on
        // whichever order builds happened to complete in. Sorted by
        // `MutationID` — an arbitrary but fixed, reproducible order — same
        // as `Self.chunked` relies on for `testAndFinish`'s non-wave path.
        let orderedAlive = stillAlive.sorted { $0.prepared.point.id < $1.prepared.point.id }

        var nextSurvivors: [WaveSurvivor] = []
        var batchCount = 0
        var totalConfigurations = 0
        var batchDurations: [Double] = []
        for chunkStart in stride(from: 0, to: orderedAlive.count, by: batchSize) {
            let chunk = Array(orderedAlive[chunkStart ..< min(chunkStart + batchSize, orderedAlive.count)])
            batchCount += 1
            totalConfigurations += chunk.count
            let (chunkResults, chunkSurvivors, duration) = await testWaveChunk(
                chunk, id: "wave-\(waveIndex)-chunk-\(chunkStart)", waveIndex: waveIndex,
                baseline: baseline, store: store, batchable: batchable
            )
            results.append(contentsOf: chunkResults)
            nextSurvivors.append(contentsOf: chunkSurvivors)
            if let duration { batchDurations.append(duration) }
        }

        return (results, nextSurvivors, batchCount, totalConfigurations, batchDurations)
    }

    /// Tests one chunk's worth of survivors — each contributing its next
    /// prioritised covering test — in a single batch, and splits them into
    /// this wave's kills (finished) and advances (returned to keep waving).
    private func testWaveChunk(
        _ chunk: [WaveSurvivor], id: String, waveIndex: Int,
        baseline: BaselineContext, store: TestPriorityStore, batchable: any BatchTestable
    ) async -> (results: [MutationResult], nextSurvivors: [WaveSurvivor], duration: Double?) {
        do {
            let batchSandbox = try await workspaces.createSandbox(id: id)
            let items = chunk.map { survivor in
                BatchMutantItem(
                    id: survivor.prepared.point.id,
                    artifact: survivor.prepared.artifact,
                    selectedTests: [survivor.remainingTests[0]]
                )
            }
            // Sized from what each survivor has *left*, not a fresh
            // mutantLimitSeconds per mutant — a survivor already close to
            // its cumulative budget must not still be granted a batch that
            // could run it for another full mutantLimitSeconds regardless
            // of what it already spent, which would let this wave alone
            // blow well past the cumulative budget the pre-wave check above
            // exists to enforce.
            let batchTimeout = chunk.reduce(0.0) { partial, survivor in
                let mutantLimitSeconds = baseline.timeouts.mutantLimitSeconds(
                    selectedTests: survivor.prepared.selectedTests
                )
                return partial + max(0, mutantLimitSeconds - survivor.cumulativeTestSeconds)
            }
            // Containment, layered underneath `batchTimeout` above (which
            // stays the outer, aggregate fail-safe, unchanged): confirmed
            // (Gate 3 Phase H1/H2) that XCTest's own per-test allowance
            // cuts one hanging configuration off — reported `.timedOut` by
            // `XCResultAdapter.classifyBatch`'s native-timeout branch,
            // routed into the same confirmation path a single-mutant
            // timeout already goes through — without killing this batch's
            // shared `xcodebuild` invocation or losing its other members'
            // results. Every member of one chunk resolves to the identical
            // `mutantLimitSeconds` today (the selected-test-width clamp
            // that could once have varied it per mutant was removed, see
            // `TimeoutController.mutantLimitSeconds(selectedTests:)`), so
            // one value covers the whole batch rather than needing
            // per-item grouping.
            //
            // `nil` — native timeout not attempted, `batchTimeout` alone
            // still applies exactly as before — in two cases: a chunk of
            // exactly one member has no attribution ambiguity for the
            // outer timeout to begin with, so there is nothing for this to
            // contain; and a resolved allowance below Phase H1's own
            // empirically-validated value (60s — the only value actually
            // exercised against a real hang) is not a value this has
            // evidence is safe against false positives from Xcode/Simulator
            // per-invocation startup overhead.
            let nativeTimeoutAllowanceSeconds: Double? = {
                guard chunk.count > 1 else { return nil }
                let allowance = baseline.timeouts.mutantLimitSeconds
                return allowance >= 60 ? allowance : nil
            }()
            let batchStarted = monotonicNow()
            let runs = await batchable.runBatch(
                items, in: batchSandbox, timeoutSeconds: batchTimeout,
                nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
            )
            let duration = monotonicNow() - batchStarted
            // What THIS mutant's own budget is charged for its share of the
            // batch — configurations in a shared invocation run
            // sequentially, not concurrently, so charging every one of them
            // the *whole* batch's wall clock (as `testDurationSeconds`
            // already does elsewhere, for reporting) would let a batch of
            // several slow-to-fail mutants exhaust every survivor's
            // cumulative budget at once, well before any of them
            // individually used that much time. An even split is an
            // approximation — real per-configuration timing isn't
            // available from the adapter — but a far more honest one than
            // charging the total to everyone.
            let perMutantShare = duration / Double(chunk.count)

            var results: [MutationResult] = []
            var nextSurvivors: [WaveSurvivor] = []
            for survivor in chunk {
                let test = survivor.remainingTests[0]
                var run = runs[survivor.prepared.point.id] ?? TestRunResult(
                    status: .infrastructureFailure, summary: nil, command: survivor.prepared.artifact.command,
                    resultArtifactPath: nil, diagnosis: "This mutant's outcome was not reported back from its wave batch."
                )
                // Real, individually-timed duration for THIS mutant, once
                // ground-truth verification below has actually measured one —
                // as opposed to `perMutantShare`, the estimate everyone in
                // this chunk gets by default.
                var verifiedDurationSeconds: Double?

                // `.infrastructureFailure`, or missing from the batch's
                // results at all, is a definitive signal about THIS mutant —
                // both are exactly what a shared invocation failing to
                // report back cleanly looks like from the outside, with no
                // way to tell whether this mutant caused it or merely shared
                // the invocation with whatever did. Found for real on a live
                // Xcode project: a chunk of exactly one survivor still
                // reported `infrastructureFailure` for a mutant that a plain
                // standalone rerun immediately confirmed was
                // `killedByAssertion` — so this is not only a multi-mutant
                // sharing problem, and the check does not gate on
                // `chunk.count`. `.failed`/`.crashed` are left alone: the
                // batch xctestrun's own attribution of an assertion failure
                // or crash to a specific configuration is a solid,
                // independent mechanism this is not second-guessing — only
                // the batch's non-answers are.
                //
                // `.timedOut` is different from the other two, and is only
                // ambiguous when `isBatchAttributedTimeout` says so (Gate 3
                // Phase H2's own field, introduced for exactly this
                // distinction, previously unused on this path — Gate 3 Phase
                // H12.1/H12.2). A native-XCTest-timeout classification
                // (`isBatchAttributedTimeout == false`) already names the one
                // configuration responsible; rerunning it standalone here
                // before `finishAfterTest` below triggers its own, separate
                // `confirmTimedOutMutants` confirmation (narrowed to this
                // same witness test) pays for the identical single-test
                // confirmation twice. Only a genuine batch-wide kill
                // (`isBatchAttributedTimeout == true` — the whole shared
                // invocation was terminated with no way to tell which
                // configuration caused it) still needs this standalone rerun
                // to find out whether THIS mutant was actually responsible.
                if (run.status == .timedOut && run.isBatchAttributedTimeout) || run.status == .infrastructureFailure
                    || runs[survivor.prepared.point.id] == nil {
                    let (standaloneRun, standaloneDuration) = await standaloneVerify(
                        survivor.prepared, selectedTests: [test], baseline: baseline
                    )
                    run = standaloneRun
                    verifiedDurationSeconds = standaloneDuration
                }

                if run.status != .passed {
                    // Confirmation (retestKilledMutants/confirmCrashKills/
                    // confirmTimedOutMutants) reruns using `selectedTests` —
                    // narrowed here to just the one test that actually
                    // produced this wave's detection, not the mutant's whole
                    // original covering-test set, so a confirmation rerun
                    // reproduces the same single witness rather than a
                    // broader run that could reach a different result.
                    //
                    // testDurationSeconds is this mutant's *total* test time
                    // across every wave, not just this final one — otherwise
                    // a mutant killed on wave 3 would report only wave 3's
                    // duration, silently dropping waves 1 and 2's.
                    let result = await finishAfterTest(
                        survivor.prepared.narrowed(to: test), baseline: baseline, run: run,
                        testDurationSeconds: survivor.cumulativeTestSeconds + (verifiedDurationSeconds ?? perMutantShare),
                        priorTestAttempts: survivor.attempts, appendCurrentAttempt: true, currentAttemptWaveIndex: waveIndex
                    )
                    // Only a confirmed kill credits this test's priority
                    // history — checked against the *final* outcome, not the
                    // raw wave `run.status`: confirmation may have just
                    // downgraded it to `.flaky` or an unconfirmed `.timedOut`,
                    // and crediting a result that did not hold up would
                    // corrupt the learned ordering. Mirrors
                    // `PrioritizingTestAdapter.runMutant`'s identical
                    // distinction on the per-invocation path.
                    if result.outcome.isKilled {
                        await store.recordDetection(by: test)
                    }
                    try? await workspaces.destroySandbox(at: survivor.prepared.sandbox)
                    results.append(result)
                } else {
                    // Passed this test → advance to the next one, carrying
                    // this wave's (per-mutant share of the, or — once ground-
                    // truth verified above — the real) duration into the
                    // running total, and this run itself forward so a later
                    // exhausted/budget-expired result can report its real
                    // command/artifact instead of a placeholder.
                    //
                    // This wave's own artifact is preserved now, before
                    // `batchSandbox` is destroyed below — otherwise a later
                    // wave/confirmation could never recover it once this
                    // survivor eventually reaches a final verdict.
                    // `survivor.prepared.sandbox` (not `batchSandbox`) is
                    // passed deliberately, the same way the single-attempt
                    // path below does for its own preserve call: several
                    // survivors in this chunk share the SAME batch-wide
                    // result bundle, and passing the sandbox it actually
                    // lives in would let the first survivor's preserve MOVE
                    // it away, leaving nothing for the rest. Passing a
                    // sandbox the artifact is never inside forces a copy.
                    let preservedArtifact = evidenceAssembler.preserve(
                        run.resultArtifactPath, for: survivor.prepared.point, in: survivor.prepared.sandbox,
                        label: "wave-\(waveIndex)"
                    )
                    let attempt = TestAttemptEvidence(
                        selectedTests: [test.onlyTestingArgument],
                        status: run.status.rawValue,
                        summary: run.summary,
                        command: run.command,
                        resultArtifact: preservedArtifact,
                        waveIndex: waveIndex
                    )
                    let advanced = Array(survivor.remainingTests.dropFirst())
                    nextSurvivors.append(WaveSurvivor(
                        prepared: survivor.prepared, remainingTests: advanced,
                        cumulativeTestSeconds: survivor.cumulativeTestSeconds + (verifiedDurationSeconds ?? perMutantShare),
                        lastRun: run,
                        attempts: survivor.attempts + [attempt]
                    ))
                }
            }

            try? await workspaces.destroySandbox(at: batchSandbox)
            return (results, nextSurvivors, duration)
        } catch {
            // No place to write this wave's batch xctestrun/result bundle:
            // every mutant in this chunk is unproven, not silently dropped,
            // and does not advance to a wave that will never run. No test
            // time was spent on this failed attempt, so the reported
            // duration is whatever this mutant had already accumulated.
            var results: [MutationResult] = []
            for survivor in chunk {
                let result = await finishAfterTest(
                    survivor.prepared, baseline: baseline,
                    run: TestRunResult(
                        status: .infrastructureFailure, summary: nil, command: survivor.prepared.artifact.command,
                        resultArtifactPath: nil, diagnosis: "No wave sandbox could be created: \(error)"
                    ),
                    testDurationSeconds: survivor.cumulativeTestSeconds
                )
                try? await workspaces.destroySandbox(at: survivor.prepared.sandbox)
                results.append(result)
            }
            return (results, [], nil)
        }
    }

    /// Ground-truth verification for a mutant whose classification would
    /// otherwise rest on shared-batch estimated timing — fair-share division
    /// of a batch's wall clock, or an ambiguous `.timedOut`/missing-from-batch
    /// result from an invocation shared with other mutants. Runs this ONE
    /// mutant standalone, through `runMutantTests` — the same trusted,
    /// individually-timed path ordinary (non-batch, non-wave) execution
    /// already uses, with nobody else's time to borrow from or be blamed for.
    ///
    /// The wave loop's own bookkeeping (fair-share division, the cumulative-
    /// budget estimate) exists only to decide *when* to reach for this check
    /// — it must never stand in for it. A caller whose `run` genuinely could
    /// not be launched here reports `.infrastructureFailure`, exactly like
    /// every other unbatched test call in this file.
    private func standaloneVerify(
        _ prepared: PreparedMutant, selectedTests: Set<TestIdentifier>?, baseline: BaselineContext
    ) async -> (run: TestRunResult, duration: Double) {
        let testStarted = monotonicNow()
        // Scaled off exactly what this standalone attempt actually runs
        // (`selectedTests`, not unconditionally `prepared.selectedTests` —
        // a caller may narrow this to the mutant's whole remaining list or
        // to a single witness test, never its original full covering-test
        // set, though `testOneBatch`'s own ambiguity-recovery call passes
        // `prepared.selectedTests` straight through since it has no
        // narrower list to prefer). `nil` here means the same thing it
        // always does — no known selection, run the full configured list —
        // preserved rather than collapsed into an empty `Set`.
        let timeoutSeconds = baseline.timeouts.mutantLimitSeconds(selectedTests: selectedTests)
        let run = try? await confirmationCoordinator.runMutantTests(
            prepared.point, artifact: prepared.artifact, in: prepared.sandbox,
            timeoutSeconds: timeoutSeconds, selectedTests: selectedTests
        )
        let duration = monotonicNow() - testStarted
        return (
            run ?? TestRunResult(
                status: .infrastructureFailure, summary: nil, command: prepared.artifact.command,
                resultArtifactPath: nil, diagnosis: "The mutant's standalone verification test could not be run."
            ),
            duration
        )
    }

    /// Tests one already-batchable group of prepared mutants through a
    /// single `runBatch` call, classifies each result, records checkpoints,
    /// and destroys each mutant's own sandbox (its clone, for the pipelined
    /// path) plus the batch sandbox. Extracted out of `testAndFinish`'s loop
    /// body so it can be shared with `runPipelinedTestLane`, which calls it
    /// once per batch as clones arrive live instead of once per pre-sliced
    /// chunk of a complete `readyToTest` array.
    ///
    /// Never throws: a batch sandbox creation failure, a missing result, or
    /// any other error is recorded as `.infrastructureFailure` for the
    /// affected mutants, same fail-closed contract every other path in this
    /// file has. Checkpoint failures are swallowed here (`try?`, not
    /// `try`) rather than propagated the way `testAndFinish`'s own
    /// non-batched fallback loop still does above — a deliberate
    /// harmonization with the build-worker paths, which have always
    /// swallowed checkpoint failures rather than aborting the run over
    /// them, and a practical necessity here: this function is called from
    /// `runPipelinedTestLane`, a non-throwing task running concurrently
    /// alongside the build workers, so a checkpoint write failure cannot be
    /// allowed to unwind through it.
    private func testOneBatch(
        _ chunk: [PreparedMutant], batchIndex: Int, baseline: BaselineContext, batchable: any BatchTestable
    ) async -> (results: [MutationResult], configurations: Int, duration: Double?) {
        var collected: [MutationResult] = []

        let batchSandbox: URL
        do {
            batchSandbox = try await workspaces.createSandbox(id: "batch-\(batchIndex)")
        } catch {
            // No place to write the batch xctestrun/result bundle: every
            // mutant in this chunk is unproven, not silently dropped. No
            // test time was spent on this failed attempt, so there is no
            // duration to report — matches `BatchExecutionSummary.
            // batchDurations`'s documented "one entry per chunk that
            // actually reached `BatchTestable.runBatch`" contract.
            for prepared in chunk {
                let result = await finishAfterTest(
                    prepared, baseline: baseline,
                    run: TestRunResult(
                        status: .infrastructureFailure, summary: nil, command: prepared.artifact.command,
                        resultArtifactPath: nil, diagnosis: "No batch sandbox could be created: \(error)"
                    )
                )
                try? await workspaces.destroySandbox(at: prepared.sandbox)
                collected.append(result)
            }
            return (collected, chunk.count, nil)
        }

        let items = chunk.map {
            BatchMutantItem(id: $0.point.id, artifact: $0.artifact, selectedTests: $0.selectedTests)
        }
        // Each mutant in the shared invocation contributes its own limit —
        // selected-test-clamped where it has a known, non-empty selection,
        // whole-suite-scaled otherwise — rather than every mutant in the
        // batch being charged the same whole-suite number regardless of how
        // narrow its own selection is.
        let batchTimeout = chunk.reduce(0.0) { partial, prepared in
            partial + baseline.timeouts.mutantLimitSeconds(selectedTests: prepared.selectedTests)
        }
        // Containment, layered underneath `batchTimeout` above (which stays
        // the outer, aggregate fail-safe, unchanged) — this is the path a
        // plain `testBatchSize > 1` configuration (`earlyAbortSelectedTests`
        // left at its default `false`) actually runs, the same path Gate
        // 3's real-production-app batch-hang-containment finding came from. See
        // `testWaveChunk`'s identical native-timeout block for the full
        // rationale (Gate 3 Phase H1/H2/H3) — repeated here rather than
        // shared because the two chunk shapes (`[WaveSurvivor]` vs
        // `[PreparedMutant]`) don't share a common type to factor a helper
        // over without a bigger refactor than this phase calls for.
        let nativeTimeoutAllowanceSeconds: Double? = {
            guard chunk.count > 1 else { return nil }
            let allowance = baseline.timeouts.mutantLimitSeconds
            return allowance >= 60 ? allowance : nil
        }()
        let batchStarted = Date()
        let runs = await batchable.runBatch(
            items, in: batchSandbox, timeoutSeconds: batchTimeout,
            nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
        )
        let batchTestDuration = Date().timeIntervalSince(batchStarted)

        for prepared in chunk {
            var run = runs[prepared.point.id] ?? TestRunResult(
                status: .infrastructureFailure, summary: nil, command: prepared.artifact.command,
                resultArtifactPath: nil,
                diagnosis: "This mutant's outcome was not reported back from its batch."
            )
            // `.infrastructureFailure` here — whether `classifyBatch` itself
            // produced it (no per-configuration evidence in the result
            // bundle) or it was synthesized just above (missing from `runs`
            // entirely) — means the *shared invocation's* attribution
            // failed for this one mutant, not that the mutant is
            // unprovable. `testWaveChunk` already has this exact gate for
            // the identical failure shape (found for real on a live Xcode
            // project — see its own doc comment); `testOneBatch`, the plain
            // non-wave batch path (`earlyAbortSelectedTests` left at its
            // default `false`), never had the equivalent protection until
            // now. `.timedOut` is deliberately left alone here — that
            // status already has its own correct, existing handling via
            // `confirmTimedOutMutants`'s policy-driven confirmation
            // (`isBatchAttributedTimeout` distinguishes a genuine
            // individually-attributed timeout from a batch-wide one), which
            // this gate must not duplicate or race against.
            var verifiedDurationSeconds: Double?
            if run.status == .infrastructureFailure {
                let (standaloneRun, standaloneDuration) = await standaloneVerify(
                    prepared, selectedTests: prepared.selectedTests, baseline: baseline
                )
                run = standaloneRun
                verifiedDurationSeconds = standaloneDuration
            }
            let result = await finishAfterTest(
                prepared, baseline: baseline, run: run, testDurationSeconds: verifiedDurationSeconds ?? batchTestDuration
            )
            try? await workspaces.destroySandbox(at: prepared.sandbox)
            collected.append(result)
        }

        try? await workspaces.destroySandbox(at: batchSandbox)
        return (collected, chunk.count, batchTestDuration)
    }

    // MARK: - Baseline

    // Phase A1 extraction: `internal` (not `fileprivate`) because
    // `MutationConfirmationCoordinator`, in its own file, takes this as a
    // parameter to every confirmation retest method.
    struct BaselineContext: Sendable {
        let record: BaselineRecord
        let productHash: String?
        let timeouts: TimeoutController
        /// Lines the baseline suite executed. `nil` means coverage was not
        /// measured; an empty-but-present map means every line was unreached.
        /// Either way the runner does not fabricate `noCoverage` from absence.
        let coverage: CoverageMap?
        /// Which tests covered which lines, when `selectCoveringTests` asked
        /// for the attribution and the adapter could produce one. `nil`
        /// means every mutant runs the full configured test list — the same
        /// safe fallback `coverage == nil` is for the `.noCoverage` check.
        let perTestCoverage: PerTestCoverageMap?
    }

    private enum BaselineAttempt {
        case established(BaselineContext)
        case failed(record: BaselineRecord, diagnosis: String)
    }

    /// Builds and tests the project unmutated.
    ///
    /// This happens in a sandbox like everything else, and not only to leave the
    /// working tree alone: the baseline's build product hash is what every
    /// mutant's is compared against, and a hash taken from a differently-shaped
    /// tree would not be comparable to one taken from a sandbox.
    private func establishBaseline() async -> BaselineAttempt {
        if let preEstablishedBaseline {
            return Self.baselineAttempt(from: preEstablishedBaseline, configuration: configuration)
        }

        let started = Date()

        let sandbox: URL
        do {
            sandbox = try await workspaces.createSandbox(id: Self.baselineSandboxID)
        } catch {
            return .failed(
                record: unusableBaseline(startedAt: started),
                diagnosis: "The baseline sandbox could not be created: \(error)"
            )
        }

        let attempt = await establishBaseline(in: sandbox, startedAt: started)
        try? await workspaces.destroySandbox(at: sandbox)
        return attempt
    }

    private func establishBaseline(in sandbox: URL, startedAt: Date) async -> BaselineAttempt {
        let timeouts = TimeoutController(settings: configuration.timeouts)

        let artifact: BuildArtifact
        do {
            artifact = try await build.buildBaseline(in: sandbox)
        } catch let failure as BuildFailure {
            return .failed(
                record: unusableBaseline(startedAt: startedAt),
                diagnosis: "The project does not build unmutated: \(failure.diagnosis)"
            )
        } catch {
            return .failed(
                record: unusableBaseline(startedAt: startedAt),
                diagnosis: "The baseline build could not be run: \(error)"
            )
        }

        let testStarted = Date()
        let run: TestRunResult
        do {
            run = try await test.runBaseline(
                artifact,
                in: sandbox,
                timeoutSeconds: timeouts.baselineLimitSeconds
            )
        } catch {
            return .failed(
                record: unusableBaseline(startedAt: startedAt, buildCommand: artifact.command),
                diagnosis: "The baseline test run could not be completed: \(error)"
            )
        }

        // The mutant limit scales the *test* duration, not build-plus-test: it is
        // handed to the test adapter, and a build that dominates the wall clock
        // would inflate every mutant's limit into uselessness.
        //
        // Measured wall clock, never the reported test duration. The limit bounds
        // a process, so it has to be derived from what that process actually
        // costs. A result bundle reports how long the assertions took — about a
        // tenth of a second for a small suite — while the command around them
        // spends half a minute booting, installing and launching a simulator.
        // Budgeting from the former gave killed mutants less time than the run
        // needs, so under load they were reported `timedOut` and dropped from the
        // score, and the same plan produced different numbers on consecutive runs.
        let testDuration = Date().timeIntervalSince(testStarted)

        let record = BaselineRecord(
            passed: run.status == .passed,
            testSummary: run.summary,
            durationSeconds: Date().timeIntervalSince(startedAt),
            buildProductHash: artifact.productHash,
            buildCommand: artifact.command,
            testCommand: run.command,
            buildDurationSeconds: testStarted.timeIntervalSince(startedAt),
            testDurationSeconds: testDuration
        )

        guard run.status == .passed else {
            return .failed(
                record: record,
                diagnosis: """
                The unmutated suite did not pass (\(run.status.rawValue)): \(run.diagnosis) Every \
                mutant is measured against this run, so nothing can be concluded until it is green.
                """
            )
        }

        // Coverage is read *before* the sandbox is destroyed — the codecov
        // files (or, for xcodebuild, the result bundle) live inside it. The
        // config flags are the source of truth: an adapter that *can*
        // measure coverage but was not asked to should not produce a map,
        // because the user has not been told the baseline would be
        // instrumented. A failed or partial read yields `nil`, which means
        // every mutant will be built and tested rather than guessed at.
        //
        // `selectCoveringTests` is tried first and, when it succeeds, its
        // union *is* the whole-suite coverage map — reading a separate
        // whole-run report would be a second, redundant read of the same
        // fact. `measureCoverage` on its own remains the lighter-weight
        // option: the `.noCoverage` fast path without paying for per-test
        // attribution.
        //
        // The per-test attribution pass is the most expensive thing the
        // baseline does on a real project (~85 minutes on the project this
        // tool was benchmarked against), and it is also the most stable:
        // it only changes when the source tree, test suite, toolchain, or
        // coverage configuration changes. So a `CoverageProfileCache` with
        // a context digest key is consulted *before* the adapter is asked
        // to re-measure. A hit skips the measurement entirely; a miss
        // measures as usual and stores the result back for the next run.
        // The baseline build and test above have already run either way —
        // the suite-must-pass gate and the timeout calibration cannot be
        // served from a cache.
        let measured = await BaselineCoverageMeasurement(
            configuration: configuration, cache: coverageCache, cacheKey: coverageCacheKey,
            operationalIssues: operationalIssues
        ).measure(
            with: test, against: artifact, in: sandbox, projectRoot: projectRoot,
            timeoutSeconds: timeouts.baselineLimitSeconds
        )
        let perTestCoverage = measured.perTestCoverage
        let coverage = measured.coverage

        // `record` above already carries everything but `profilingDurationSeconds`
        // — needed for the failure-path `guard` above, before coverage
        // measurement has happened at all. This second record is identical
        // except for that one field, built only once the baseline is known to
        // have passed and coverage measurement has been attempted.
        let recordWithProfiling = BaselineRecord(
            passed: record.passed,
            testSummary: record.testSummary,
            durationSeconds: record.durationSeconds,
            buildProductHash: record.buildProductHash,
            buildCommand: record.buildCommand,
            testCommand: record.testCommand,
            buildDurationSeconds: record.buildDurationSeconds,
            testDurationSeconds: record.testDurationSeconds,
            profilingDurationSeconds: measured.profilingDurationSeconds
        )

        return .established(BaselineContext(
            record: recordWithProfiling,
            productHash: artifact.productHash,
            timeouts: timeouts.recordingBaseline(durationSeconds: testDuration),
            coverage: coverage,
            perTestCoverage: perTestCoverage
        ))
    }

    /// Converts a `SharedBaselineEstablisher` result into this runner's own
    /// `BaselineAttempt` shape — the `preEstablishedBaseline` short-circuit
    /// in `establishBaseline()`'s only caller. `static`, not an instance
    /// method: it touches no runner state beyond `configuration` (passed
    /// explicitly), matching `BaselineContext`'s own construction in the
    /// non-injected path exactly (`timeouts.recordingBaseline`,
    /// `coverage`/`perTestCoverage` verbatim) so a mutant scored against an
    /// injected baseline is measured identically to one scored against a
    /// baseline this runner established itself.
    private static func baselineAttempt(
        from outcome: SharedBaselineEstablisher.Outcome, configuration: Configuration
    ) -> BaselineAttempt {
        switch outcome {
        case let .failed(record, diagnosis):
            return .failed(record: record, diagnosis: diagnosis)
        case let .established(shared):
            return .established(BaselineContext(
                record: shared.record,
                productHash: shared.record.buildProductHash,
                timeouts: TimeoutController(settings: configuration.timeouts).recordingBaseline(durationSeconds: shared.testDurationSeconds),
                coverage: shared.coverage,
                perTestCoverage: shared.perTestCoverage
            ))
        }
    }

    private func unusableBaseline(startedAt: Date, buildCommand: CommandRecord? = nil) -> BaselineRecord {
        BaselineRecord(
            passed: false,
            // A baseline that never ran has no counts. Zeroes here would claim it
            // ran a suite of no tests, which is a different — and much less
            // alarming — statement than "we never got a baseline at all".
            testSummary: nil,
            durationSeconds: Date().timeIntervalSince(startedAt),
            buildProductHash: nil,
            buildCommand: buildCommand,
            testCommand: nil
        )
    }

    /// The report for a run that never legitimately started.
    ///
    /// Reconciling against the plan here would bury the one fact that matters
    /// under a `plannedMutationWithoutResult` for every mutation in the file. The
    /// baseline failed; nothing else was attempted, and the report says exactly
    /// that. `RunReport` withholds the score on its own once integrity fails.
    private func failClosedReport(startedAt: Date, baseline: BaselineRecord, diagnosis: String) -> RunReport {
        RunReport(
            planID: plan.planID,
            startedAt: startedAt,
            finishedAt: Date(),
            projectRoot: projectRoot.path,
            toolchain: toolchain,
            baseline: baseline,
            ledger: ResultLedger<MutationResult>(),
            integrity: IntegrityReport(
                discovered: plan.discoveredCount,
                planned: plan.mutations.count,
                sourceApplied: 0,
                buildObserved: 0,
                buildFailures: 0,
                executed: 0,
                classified: 0,
                reported: 0,
                explicitlySkipped: plan.skipped.count,
                skippedByReason: SkipReasonCount.tally(plan.skipped),
                violations: [IntegrityViolation(kind: .baselineMismatch, detail: diagnosis)]
            )
        )
    }

    // MARK: - One mutant

    /// A mutant that finished everything up through its build and is ready
    /// for a test run — shared shape between the per-mutant path and
    /// `evaluateInBatches`.
    ///
    /// Phase A1 extraction: `internal` (not `fileprivate`) because
    /// `MutationConfirmationCoordinator`, in its own file, takes this as a
    /// parameter to `confirmKillIfNeeded`.
    struct PreparedMutant: Sendable {
        let point: MutationPoint
        let sandbox: URL
        let applied: AppliedMutation
        let artifact: BuildArtifact
        let activation: ActivationEvidence?
        let observation: CoverageObservation?
        let selectedTests: Set<TestIdentifier>?
        let startedAt: Date
        /// Every `PreparedMutant` by construction came from a successful
        /// `build.buildMutant` call, so this is never `nil`.
        let buildDurationSeconds: Double
        /// F3 zero-base review, verdict-contamination audit: an independent
        /// clone of this mutant's own build products, established by
        /// `prepare(_:in:baseline:startedAt:)` immediately after the build
        /// succeeds — strictly *before* the primary test run below ever
        /// starts, and therefore before any `ProcessSupervisor`-spawned
        /// process from that primary run, escaped or not, has ever had any
        /// chance to write into it. `confirmKill` uses this instead of
        /// `sandbox` — see that function's own doc comment for the actual
        /// threat this closes. `nil` only when
        /// `Configuration.execution.retestKilledMutants` is off (no
        /// confirmation retest will ever be attempted, so nothing needs
        /// isolating) or the eager clone itself failed (`prepare`'s own
        /// `.finished(.infrastructureFailure)` short-circuit in that case —
        /// see there).
        let confirmationSandbox: URL?

        /// A copy narrowed to exactly one test — used when a wave's
        /// detection came from a single covering test, so a confirmation
        /// rerun (`retestKilledMutants`/`confirmCrashKills`/
        /// `confirmTimedOutMutants`) reproduces that same witness instead of
        /// the mutant's whole original covering-test set.
        func narrowed(to test: TestIdentifier) -> PreparedMutant {
            PreparedMutant(
                point: point, sandbox: sandbox, applied: applied, artifact: artifact,
                activation: activation, observation: observation, selectedTests: [test],
                startedAt: startedAt, buildDurationSeconds: buildDurationSeconds,
                confirmationSandbox: confirmationSandbox
            )
        }
    }

    private enum PrepareOutcome {
        case finished(MutationResult)
        case readyToTest(PreparedMutant)
    }

    /// Evaluates one mutation. Never throws: every planned mutation owes the
    /// integrity check a result, and a thrown error would silently become a
    /// missing one.
    private func evaluate(_ point: MutationPoint, baseline: BaselineContext) async -> MutationResult {
        let started = Date()

        let sandbox: URL
        do {
            sandbox = try await workspaces.createSandbox(id: point.id.rawValue)
        } catch {
            return await evidenceAssembler.infrastructureFailureResult(
                point: point,
                diagnosis: "No sandbox could be created for this mutant: \(error)",
                durationSeconds: Date().timeIntervalSince(started)
            )
        }

        let result = await evaluate(point, in: sandbox, baseline: baseline, startedAt: started)
        try? await workspaces.destroySandbox(at: sandbox)
        return result
    }

    private func evaluate(
        _ point: MutationPoint,
        in sandbox: URL,
        baseline: BaselineContext,
        startedAt: Date
    ) async -> MutationResult {
        switch await prepare(point, in: sandbox, baseline: baseline, startedAt: startedAt) {
        case let .finished(result):
            return result
        case let .readyToTest(prepared):
            let testStarted = Date()
            let run: TestRunResult
            do {
                run = try await confirmationCoordinator.runMutantTests(
                    point,
                    artifact: prepared.artifact,
                    in: sandbox,
                    timeoutSeconds: baseline.timeouts.mutantLimitSeconds(selectedTests: prepared.selectedTests),
                    selectedTests: prepared.selectedTests
                )
            } catch {
                return await evidenceAssembler.infrastructureFailureResult(
                    point: point,
                    diagnosis: "The mutant's tests could not be run: \(error)",
                    evidence: evidenceAssembler.evidence(
                        prepared.applied, artifact: prepared.artifact, activation: prepared.activation
                    ),
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    buildDurationSeconds: prepared.buildDurationSeconds,
                    testDurationSeconds: Date().timeIntervalSince(testStarted)
                )
            }
            let testDurationSeconds = Date().timeIntervalSince(testStarted)
            return await finishAfterTest(prepared, baseline: baseline, run: run, testDurationSeconds: testDurationSeconds)
        }
    }

    /// One mutant, up through the build — everything about its evaluation
    /// that does not need a test run. Shared by the per-mutant path above
    /// and `evaluateInBatches`, so a mutant is prepared identically no
    /// matter which path is about to test it: `.finished` for a verdict
    /// that needed no test at all (an anchor that no longer matches,
    /// `.noCoverage`, a build that failed to produce a testable artifact,
    /// or — isolated mode only — a build product already proven identical
    /// to the baseline's, see the short-circuit below), `.readyToTest` for
    /// one whose build succeeded and still needs running.
    private func prepare(
        _ point: MutationPoint,
        in sandbox: URL,
        baseline: BaselineContext,
        startedAt: Date
    ) async -> PrepareOutcome {
        func finished(
            sourceApplication: SourceApplicationOutcome? = nil,
            build: BuildObservation? = nil,
            coverage: CoverageObservation? = nil,
            infrastructureFailureDiagnosis: String? = nil,
            buildDurationSeconds: Double? = nil
        ) async -> PrepareOutcome {
            .finished(await evidenceAssembler.finalize(
                point: point,
                sourceApplication: sourceApplication,
                build: build,
                coverage: coverage,
                infrastructureFailureDiagnosis: infrastructureFailureDiagnosis,
                durationSeconds: Date().timeIntervalSince(startedAt),
                buildDurationSeconds: buildDurationSeconds
            ))
        }

        func infrastructureFailure(
            _ diagnosis: String, evidence: MutationEvidence? = nil, buildDurationSeconds: Double? = nil
        ) async -> PrepareOutcome {
            await finished(
                sourceApplication: evidence.map { .applied($0) },
                infrastructureFailureDiagnosis: diagnosis,
                buildDurationSeconds: buildDurationSeconds
            )
        }

        let sourceURL: URL
        do {
            sourceURL = try workspaces.resolveSourceURL(in: sandbox, relativePath: point.file)
        } catch {
            return await infrastructureFailure("\(point.file) could not be located inside the sandbox: \(error)")
        }

        let applied: AppliedMutation
        do {
            applied = try MutationApplication.applyInPlace(point, fileAt: sourceURL)
        } catch let error as ApplicationError {
            // No evidence is attached on purpose: for a mutation that was never
            // written, the absence of a diff is the honest record, and
            // `notApplied` is exempt from the phantom check for that reason.
            switch error {
            case let .anchorRejected(verification):
                return await finished(sourceApplication: .notApplied(diagnosis: verification.diagnosis))
            case let .unreadableFile(path, underlying):
                return await infrastructureFailure("The sandboxed copy of \(path) could not be read: \(underlying)")
            case let .unwritableFile(path, underlying):
                return await infrastructureFailure("The mutation could not be written to \(path): \(underlying)")
            }
        } catch {
            return await infrastructureFailure("The mutation could not be applied: \(error)")
        }

        // Fast path: a baseline coverage map that knows this line was never
        // executed lets us classify the mutant without building or testing it.
        // The mutation is on a line the suite does not reach, so the verdict is
        // `noCoverage` regardless of what a run would say — and skipping the
        // build is a large fraction of the speedup the design promises.
        //
        // The mutation was applied to the source, so the evidence carries a real
        // diff. The build product hash is left `nil` and the activation evidence
        // is `nil`, which is exactly the honest record for a mutant that was
        // never built. `isReportable` is satisfied by the source diff alone, and
        // `noCoverage` is not flagged by the activation check, so this result
        // enters the score without a phantom or unproven-activation violation.
        if let coverage = baseline.coverage, coverage.isKnownUncovered(point) {
            let observation = coverage.observation(forFile: point.file, line: point.line)
            return await finished(
                sourceApplication: .applied(evidenceAssembler.evidence(applied)),
                coverage: CoverageObservation(mutatedLineWasExecuted: false, source: observation?.source ?? "baseline coverage")
            )
        }

        let observation = baseline.coverage?.observation(forFile: point.file, line: point.line)

        // An empty result is never used: it would mean "run nothing", which
        // a coverage-blind run can't tell apart from a test that legitimately
        // has none. `nil` — unknown attribution, or none configured — always
        // falls back to the full configured test list inside the adapter.
        let selectedTests = baseline.perTestCoverage
            .flatMap { $0.testsCovering(file: point.file, line: point.line) }
            .flatMap { $0.isEmpty ? nil : $0 }

        let artifact: BuildArtifact
        let buildStarted = Date()
        do {
            artifact = try await build.buildMutant(applied, in: sandbox)
        } catch let failure as BuildFailure {
            return await finished(
                sourceApplication: .applied(evidenceAssembler.evidence(applied, buildCommand: failure.command)),
                build: BuildObservation(outcome: .failed(kind: failure.kind, diagnosis: failure.diagnosis, command: failure.command)),
                buildDurationSeconds: Date().timeIntervalSince(buildStarted)
            )
        } catch {
            return await infrastructureFailure(
                "The mutant's build could not be run: \(error)",
                evidence: evidenceAssembler.evidence(applied),
                buildDurationSeconds: Date().timeIntervalSince(buildStarted)
            )
        }
        let buildDurationSeconds = Date().timeIntervalSince(buildStarted)

        let activation = MutationEvidenceAssembler.activationEvidence(
            mutantHash: artifact.productHash,
            baselineHash: baseline.productHash
        )

        // Short-circuit: in isolated mode the mutation is compiled directly
        // into the binary, so a build product already identical to the
        // baseline's needs no test run to classify. This comparison runs
        // once, immediately after the build and strictly before any test is
        // ever attempted for this mutant — so `.timedOut` and `.flaky`
        // cannot already exist at this point; both are outcomes of an
        // actual test run (`.flaky` only as a *second*, confirming run
        // disagreeing with a first — see `MutationVerdictVerifier
        // .confirmKill`/`confirmCrash`), which by construction has not
        // happened yet.
        //
        // What the suite *would* report if run anyway is a separate
        // question, and it does not have one uniform answer.
        // `MutationVerdictVerifier.classify` routes `.passed`/`.failed`/
        // `.crashed` through `unprovenActivation` and downgrades every one
        // of them to `.infrastructureFailure` once activation is unproven —
        // for those three, running the suite here really would only ever
        // confirm what this comparison already knows, at the cost of the
        // full test-execution wall-clock. But `.timedOut` bypasses that gate
        // entirely: `classify` always reports a hang as `.timedOut`
        // regardless of activation. Had this short-circuit not existed and
        // a hash-identical mutant's tests hung, the verdict would have been
        // `.timedOut` — and, if `confirmTimedOutMutants` reproduced it on
        // an independent rebuild, ultimately `.verifiedTimeout`, which this
        // codebase credits as a real kill — for a mutation that never
        // reached the binary at all. So for the timeout path specifically,
        // skipping the run does not just avoid a redundant confirmation; it
        // closes a route to a false kill credit that running the suite
        // would otherwise have opened. (Schemata mode has no equivalent:
        // one shared build embeds every mutation, so there is no per-mutant
        // pre-test hash to compare — activation there can only be
        // established by the runtime hit protocol during the test itself.)
        //
        // Round-2 review M2: the "identical to baseline" claim this
        // short-circuit trusts completely comes from `MachOCodeHash`, which
        // has been wrong before in exactly this direction — issue #3 (see
        // its own doc comment) was a real, CI-confirmed false positive
        // where a mutation that genuinely reached the binary and genuinely
        // failed a test still hashed identical to baseline, because the
        // difference lived in linkage rather than in any hashed section's
        // bytes. Before this short-circuit existed, running the suite on
        // every mutant was the safety net that surfaced that: a
        // hash-identical mutant whose tests still failed was a visible
        // contradiction, right here in this run's own diagnosis text. This
        // short-circuit retires that net for every hash-matched mutant,
        // since none of their tests run at all any more — see
        // `Configuration.execution.noOpCanarySampleRate` for the narrow,
        // deterministic, opt-in slice of it this reopens.
        if case .buildProductIdenticalToBaseline? = activation, !isNoOpCanarySample(point.id) {
            return await finished(
                sourceApplication: .applied(evidenceAssembler.evidence(applied, artifact: artifact, activation: activation)),
                build: BuildObservation(
                    outcome: .succeeded(buildProductHash: artifact.productHash, command: artifact.command),
                    durationSeconds: buildDurationSeconds
                ),
                infrastructureFailureDiagnosis: """
                The mutant's build product is identical to the baseline's, so the mutation never reached the code \
                under test, and this result proves nothing. Tests were skipped rather than run against a build \
                already known to contain no mutation.
                """,
                buildDurationSeconds: buildDurationSeconds
            )
        }

        // F3 zero-base review, verdict-contamination audit: cloned here —
        // immediately after the build succeeds, strictly *before* the
        // caller ever runs this mutant's primary test — so that
        // `confirmKill`'s later retest (see that function's own doc
        // comment) never executes anywhere a `ProcessSupervisor`-escaped
        // descendant from *this exact* primary run could still be writing.
        // Cloning any later than this — even "right before `confirmKill`
        // itself runs" — would not be safe: that descendant is still alive
        // for however long it happens to survive, so a clone taken after
        // the primary run merely races it instead of avoiding it entirely.
        // See `establishConfirmationSandbox` for the clone itself and its
        // own infrastructure-failure handling.
        let (confirmationSandbox, confirmationFailure) = await establishConfirmationSandbox(
            ConfirmationSandboxRequest(
                point: point, applied: applied, artifact: artifact, activation: activation,
                coverage: observation, buildDurationSeconds: buildDurationSeconds
            ),
            startedAt: startedAt
        )
        if let confirmationFailure { return confirmationFailure }

        return .readyToTest(PreparedMutant(
            point: point,
            sandbox: sandbox,
            applied: applied,
            artifact: artifact,
            activation: activation,
            observation: observation,
            selectedTests: selectedTests,
            startedAt: startedAt,
            buildDurationSeconds: buildDurationSeconds,
            confirmationSandbox: confirmationSandbox
        ))
    }

    /// Clones this mutant's own independent confirmation workspace out of
    /// its just-built products directory, before `prepare` ever hands this
    /// mutant off for its primary test.
    ///
    /// F3 zero-base review, verdict-contamination audit: called
    /// immediately after the build succeeds, strictly *before* this
    /// mutant's primary test ever runs — so that `confirmKill`'s later
    /// retest (see that function's own doc comment) never executes
    /// anywhere a `ProcessSupervisor`-escaped descendant from *this exact*
    /// primary run could still be writing. Calling this any later — even
    /// "right before `confirmKill` itself runs" — would not be safe: that
    /// descendant is still alive for however long it happens to survive,
    /// so a clone taken after the primary run merely races it instead of
    /// avoiding it entirely. Only paid when a confirmation retest could
    /// ever actually be attempted; `cloneProducts` clones the already-built
    /// products directory (`clonefile` on APFS — not a real byte-for-byte
    /// copy) rather than rebuilding, so this stays cheap relative to the
    /// build that already happened, even though it runs for every mutant
    /// this gate applies to, not just the ones that end up `.failed`.
    ///
    /// Returns `(nil, nil)` when no confirmation could ever be attempted
    /// (`retestKilledMutants` off), `(url, nil)` with the clone's location,
    /// or `(nil, outcome)` carrying the already-finalized `PrepareOutcome`
    /// for the caller — `prepare`'s own — to return directly.
    private func establishConfirmationSandbox(
        _ request: ConfirmationSandboxRequest, startedAt: Date
    ) async -> (sandbox: URL?, failure: PrepareOutcome?) {
        guard configuration.execution.retestKilledMutants else { return (nil, nil) }
        do {
            // Chooses the flat or nested clone shape per `test`'s own
            // conformance -- see `PackageManifestConfirmationRetesting`.
            let sandbox = try await workspaces.cloneProductsForConfirmationRetest(
                from: request.artifact.productsDirectory, id: "\(request.point.id.rawValue)-confirm", for: test
            )
            return (sandbox, nil)
        } catch {
            let result = await evidenceAssembler.finalize(
                point: request.point,
                sourceApplication: .applied(
                    evidenceAssembler.evidence(request.applied, artifact: request.artifact, activation: request.activation)
                ),
                build: BuildObservation(
                    outcome: .succeeded(buildProductHash: request.artifact.productHash, command: request.artifact.command),
                    durationSeconds: request.buildDurationSeconds
                ),
                coverage: request.coverage,
                infrastructureFailureDiagnosis: """
                This mutant built successfully, but its own independent confirmation workspace could not be \
                cloned out ahead of testing: \(error). Testing was skipped rather than proceed without \
                confirmKill's own required isolation from this run's primary test.
                """,
                durationSeconds: Date().timeIntervalSince(startedAt),
                buildDurationSeconds: request.buildDurationSeconds
            )
            return (nil, .finished(result))
        }
    }

    /// Deterministic membership test for `Configuration.execution
    /// .noOpCanarySampleRate`'s sample of hash-matched "no-op" mutants —
    /// see the short-circuit above and that setting's own doc comment for
    /// why this exists.
    ///
    /// Keyed off the mutation's own stable `MutationID` rather than a random
    /// draw, so the same plan always samples the same canaries run to
    /// run — this type's own top-level doc comment promises "two runs of
    /// the same plan produce the same report", and a `Bool.random()` here
    /// would break that promise for every hash-matched mutant. `ContentHash
    /// .uint64` turns the ID into a value uniform over the full `UInt64`
    /// range; comparing its position in that range against `rate` is the
    /// continuous form of `hash % n == 0`, without requiring `rate` to
    /// divide evenly into any particular `n`.
    private func isNoOpCanarySample(_ id: MutationID) -> Bool {
        let rate = configuration.execution.noOpCanarySampleRate
        guard rate > 0 else { return false }
        guard rate < 1 else { return true }
        let position = Double(ContentHash.uint64(of: id.rawValue)) / Double(UInt64.max)
        return position < rate
    }

    /// Logs the canary contradiction `finishAfterTest` detects: a mutant
    /// `MachOCodeHash` swore reached the binary unchanged, whose real test
    /// run did not simply pass anyway. Recorded both to stderr (for a human
    /// watching the run live) and to `RunReport.operationalIssues` (for a
    /// reader of `report.json` afterward), the same two places
    /// `finalize`'s checkpoint-write failure already uses — this is
    /// exactly as "the run's own score does not depend on it, but it must
    /// not silently vanish" as that one is.
    private func recordNoOpCanaryAnomaly(_ point: MutationPoint, run: TestRunResult) async {
        let diagnosis = """
        noOpCanarySampleRate canary for \(point.id): the build product hashed identical to baseline, but the \
        real test run reported \(run.status.rawValue) rather than passing (\(run.diagnosis)). A mutation that \
        never reached the binary cannot make a suite that passes on baseline behave differently — this is the \
        same shape of contradiction issue #3 exposed in MachOCodeHash, and is worth investigating as a possible \
        false "identical to baseline" claim rather than assumed harmless.
        """
        FileHandle.standardError.write(Data("warning: \(diagnosis)\n".utf8))
        await operationalIssues.append(
            OperationalIssue(severity: .warning, kind: .noOpCanaryUnexpectedOutcome, mutationID: point.id, diagnosis: diagnosis)
        )
    }

    /// The other half of a prepared mutant's evaluation: gather whatever
    /// confirmation observations `Configuration.execution` calls for, then
    /// hand the complete `MutationObservations` to `finalize` exactly
    /// once. `run` may have come from `runMutantTests` (the per-mutant
    /// path) or from a batch (`evaluateInBatches`) — this function does
    /// not know or care which, so a batched and an unbatched mutant with
    /// the same test outcome are classified identically.
    ///
    /// ADR-0006 Stage 1: whether to gather a confirmation is decided from
    /// `run`'s own raw `status` and `prepared.activation`'s own
    /// `provesActivation` — never from a classification computed ahead of
    /// the verifier, which is the whole point of this stage. The verifier
    /// (inside `finalize`) is the only place that turns the resulting
    /// observation set into an outcome.
    /// - Parameters:
    ///   - priorTestAttempts: earlier waves' evidence this mutant already
    ///     went through (see `WaveSurvivor.attempts`) — empty outside
    ///     wave-based early kill.
    ///   - appendCurrentAttempt: whether `run` itself is a NEW attempt to
    ///     record (true for a real invocation: a wave's own test, or a
    ///     standalone ground-truth verification) as opposed to a synthetic
    ///     repackaging of a survivor's already-recorded last wave (the
    ///     `exhausted` case in `testOneWave`, where `run` merely restates
    ///     `priorTestAttempts`'s own last entry and appending it again would
    ///     duplicate it).
    ///   - currentAttemptWaveIndex: which wave `run` belongs to, when
    ///     `appendCurrentAttempt` is true and it came from a specific wave —
    ///     `nil` for a standalone verification, which is not itself a wave.
    private func finishAfterTest(
        _ prepared: PreparedMutant,
        baseline: BaselineContext,
        run: TestRunResult,
        testDurationSeconds: Double? = nil,
        priorTestAttempts: [TestAttemptEvidence] = [],
        appendCurrentAttempt: Bool = false,
        currentAttemptWaveIndex: Int? = nil
    ) async -> MutationResult {
        var confirmations: [ConfirmationObservation] = []
        var crashConfirmation: CrashConfirmation?
        var timeoutConfirmation: TimeoutConfirmation?
        var confirmationDurationSeconds: Double?
        let activationProven = prepared.activation?.provesActivation ?? false

        // Round-2 review M2: a hash-matched ("no-op") mutant only ever
        // reaches a real `run` here when `noOpCanarySampleRate` sampled it
        // as a canary — see `prepare`'s short-circuit and that setting's own
        // doc comment. `.passed` is the only outcome consistent with the
        // hash's claim that the mutation never reached the binary; anything
        // else contradicts it, which is exactly the shape issue #3 took (a
        // false "identical", exposed only by the suite genuinely not
        // passing). `MutationVerdictVerifier.classify` still applies its own
        // rules below, same as always — this only makes sure the
        // contradiction itself is not lost inside whatever bucket that
        // produces.
        if case .buildProductIdenticalToBaseline? = prepared.activation, run.status != .passed {
            await recordNoOpCanaryAnomaly(prepared.point, run: run)
        }

        // Retesting only ever moves a verdict *out* of a kill, never into
        // one — a mutant that survived or crashed is not re-run, because
        // the failure mode this guards against is a flake being mistaken
        // for a kill, not the reverse. See `Configuration.execution
        // .retestKilledMutants`.
        // F3 zero-base review, verdict-contamination audit: `confirmKill`
        // always reuses whatever sandbox/artifact it is handed — never
        // `prepared.sandbox`/`prepared.artifact` directly (the primary
        // run's own home) — always `prepared.confirmationSandbox`, an
        // independent clone `prepare` established before this mutant's
        // primary test ever ran. See `confirmKillIfNeeded`.
        if let (observation, durationSeconds) = await confirmationCoordinator.confirmKillIfNeeded(
            prepared, baseline: baseline, run: run, activationProven: activationProven
        ) {
            confirmations.append(observation)
            confirmationDurationSeconds = (confirmationDurationSeconds ?? 0) + durationSeconds
        }

        // A crash gets a fresh, independent rebuild rather than a same-sandbox
        // retest — see `Configuration.execution.confirmCrashKills`'s doc comment
        // for why the same-artifact retest `retestKilledMutants` uses for
        // assertion kills is not enough here.
        if configuration.execution.confirmCrashKills, run.status == .crashed, activationProven {
            let confirmationStarted = Date()
            let (observation, crashEvidence) = await confirmationCoordinator.confirmCrashKill(
                prepared.point, baseline: baseline, selectedTests: prepared.selectedTests, originalDiagnosis: run.diagnosis
            )
            confirmations.append(observation)
            crashConfirmation = crashEvidence
            confirmationDurationSeconds = (confirmationDurationSeconds ?? 0) + Date().timeIntervalSince(confirmationStarted)
        }

        // Same shape as the crash confirmation above, for the same reason: a
        // hang has no diff to check against, so it gets a fresh, independent
        // rebuild rather than a same-sandbox retest. See
        // `Configuration.execution.confirmTimedOutMutants`. Unlike the other
        // two gates, this one does not also require `activationProven`: a
        // `.timedOut` mutant's own activation is often unknown (the build
        // may never have produced a comparable hash under a hung test), and
        // the whole point of the confirming rebuild is to establish that
        // proof, not require it up front.
        if configuration.execution.confirmTimedOutMutants, run.status == .timedOut {
            let confirmationStarted = Date()
            let confirmed = await confirmationCoordinator.confirmTimeout(
                prepared.point, baseline: baseline, selectedTests: prepared.selectedTests,
                wasBatchAttributed: run.isBatchAttributedTimeout
            )
            confirmations.append(contentsOf: confirmed.observations)
            timeoutConfirmation = confirmed.timeoutConfirmation
            crashConfirmation = confirmed.crashConfirmation
            confirmationDurationSeconds = (confirmationDurationSeconds ?? 0) + Date().timeIntervalSince(confirmationStarted)
        }

        // `confirmationSandbox` was created eagerly, before this mutant's
        // verdict was known (see its own doc comment on `PreparedMutant`),
        // so it must be disposed here unconditionally — whether or not
        // `run.status == .failed` actually used it above. `finishAfterTest`
        // is this mutant's one terminal call (every caller reaches it
        // exactly once — wave-based early kill carries `prepared` forward
        // across waves without ever re-preparing it), so this is not
        // reachable more than once per mutant.
        if let confirmationSandbox = prepared.confirmationSandbox {
            try? await workspaces.destroySandbox(at: confirmationSandbox)
        }

        let resultArtifact = evidenceAssembler.preserve(run.resultArtifactPath, for: prepared.point, in: prepared.sandbox)
        var testAttempts = priorTestAttempts
        if appendCurrentAttempt {
            testAttempts.append(TestAttemptEvidence(
                selectedTests: prepared.selectedTests?.map(\.onlyTestingArgument),
                status: run.status.rawValue,
                summary: run.summary,
                command: run.command,
                resultArtifact: resultArtifact,
                waveIndex: currentAttemptWaveIndex
            ))
        }

        return await evidenceAssembler.finalize(
            point: prepared.point,
            sourceApplication: .applied(evidenceAssembler.evidence(
                prepared.applied,
                artifact: prepared.artifact,
                activation: prepared.activation,
                testCommand: run.command,
                resultArtifact: resultArtifact,
                crashConfirmation: crashConfirmation,
                timeoutConfirmation: timeoutConfirmation,
                testAttempts: testAttempts
            )),
            build: BuildObservation(outcome: .succeeded(buildProductHash: prepared.artifact.productHash, command: prepared.artifact.command)),
            coverage: prepared.observation,
            test: SingleTestObservation(run: run, applicationEvidence: prepared.activation.map { .isolated($0) }),
            confirmations: confirmations,
            durationSeconds: Date().timeIntervalSince(prepared.startedAt),
            buildDurationSeconds: prepared.buildDurationSeconds,
            testDurationSeconds: testDurationSeconds,
            confirmationDurationSeconds: confirmationDurationSeconds
        )
    }
}

/// Thread-safe result and batch-stat accumulator for the pipelined
/// incremental+batch path, where build workers and the test lane produce
/// results concurrently from separate tasks. Both sides `add`/`addAll` as
/// they go; `evaluateIncrementallyInBatches` takes a single `snapshot` once
/// every task has finished.
private actor PipelineCollector {
    private(set) var results: [MutationResult] = []
    private(set) var batchCount = 0
    private(set) var totalConfigurations = 0
    private(set) var batchDurations: [Double] = []

    func add(_ result: MutationResult) {
        results.append(result)
    }

    func addAll(_ newResults: [MutationResult]) {
        results.append(contentsOf: newResults)
    }

    func recordBatch(configurations: Int, duration: Double?) {
        batchCount += 1
        totalConfigurations += configurations
        if let duration { batchDurations.append(duration) }
    }

    func snapshot() -> (results: [MutationResult], summary: BatchExecutionSummary) {
        (
            results,
            BatchExecutionSummary(
                batchCount: batchCount, totalConfigurations: totalConfigurations, batchDurations: batchDurations
            )
        )
    }
}

/// The single point of coordination between the pipelined incremental+batch
/// path's build workers and its one test lane: a many-producer,
/// one-consumer channel of cloned, ready-to-test mutants, *and* the
/// per-worker sandbox-lifetime tracker, combined into one actor on purpose.
///
/// **Why combined.** A worker's own persistent sandbox must stay alive
/// until every clone it produced has been tested — see
/// `evaluateIncrementallyInBatches`'s doc comment for why a single "all
/// builds are done" barrier (which is what the non-pipelined design could
/// rely on) no longer exists once build and test overlap. The natural fix
/// is a per-worker outstanding-clone reference count: incremented when a
/// clone is hand-off to the test lane, decremented when the test lane
/// finishes testing it, and the sandbox destroyed the instant a worker's
/// build loop has ended *and* that count is zero. That increment has to
/// happen atomically with the clone actually becoming visible to the test
/// lane — if `send` returned and only *then*, in a separate actor hop, bumped
/// the count, a test lane fast enough to receive and finish that clone in
/// between could call `finishedTesting` before the increment ever ran,
/// under-counting the outstanding total and destroying the sandbox while a
/// sibling clone from the same worker is still being tested. Making `send`
/// and the increment one isolated method on one actor removes that window
/// entirely: nothing can observe the state between "queued" and "counted".
///
/// **Channel half.** `send` delivers a clone to a waiting `receive` call
/// directly when the test lane is already waiting, or buffers it otherwise.
/// `receive` drains the buffer first, then waits, and returns `nil` once
/// every worker has called `workerBuildFinished` and the buffer is empty —
/// the only shutdown signal it needs, requiring no separate "close" call
/// from the runner.
///
/// **Lifetime half.** `registerWorker` records a worker's sandbox (or `nil`,
/// for a worker whose sandbox never got created); `send` bumps that
/// worker's outstanding count; `finishedTesting` decrements it;
/// `workerBuildFinished` marks the worker's build loop as ended. A worker's
/// sandbox is destroyed by `destroyIfEligible`, called after every state
/// change that could make a worker newly eligible (`workerBuildFinished`
/// and `finishedTesting`), exactly once — `destroyed` guards against a
/// worker whose build ends after its outstanding count is already zero
/// (the common case) *and* a worker whose last clone finishes testing after
/// its build has already ended (the concurrent case) both trying to tear
/// down the same sandbox.
private actor PipelineCoordinator {
    /// One clone, still tagged with the worker whose build produced it —
    /// the test lane needs the tag to know which worker's outstanding count
    /// to decrement once this clone's test result is in hand.
    struct Delivery: Sendable {
        let workerID: String
        let item: MutationRunner.PreparedMutant
    }

    private struct WorkerState {
        var sandbox: URL?
        var buildFinished = false
        var outstandingClones = 0
        var destroyed = false
    }

    private let workspaces: WorkspaceManager
    private var workers: [String: WorkerState] = [:]
    private var unfinishedWorkers: Int
    private var buffered: [Delivery] = []
    private var waiters: [CheckedContinuation<Delivery?, Never>] = []

    init(workspaces: WorkspaceManager, workerCount: Int) {
        self.workspaces = workspaces
        unfinishedWorkers = workerCount
    }

    /// Records a worker's own persistent sandbox — or `nil`, when that
    /// worker never managed to create one — before it starts (or, for the
    /// `nil` case, instead of) building. Must be called once per worker
    /// before that worker's first `send`, so `destroyIfEligible` always has
    /// a `WorkerState` to look up.
    func registerWorker(_ id: String, sandbox: URL?) {
        workers[id] = WorkerState(sandbox: sandbox)
    }

    /// Hands a clone to the test lane and, atomically with that handoff,
    /// records it against `workerID`'s outstanding count. See the type's
    /// doc comment for why this has to be one call, not two.
    func send(_ item: MutationRunner.PreparedMutant, workerID: String) {
        workers[workerID, default: WorkerState()].outstandingClones += 1
        let delivery = Delivery(workerID: workerID, item: item)
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: delivery)
        } else {
            buffered.append(delivery)
        }
    }

    /// The test lane's pull side. Drains anything already buffered first;
    /// once nothing is buffered and every worker has finished building,
    /// returns `nil` — there is nothing left this channel will ever
    /// deliver. Otherwise suspends until the next `send` or the last
    /// `workerBuildFinished`.
    func receive() async -> Delivery? {
        if !buffered.isEmpty {
            return buffered.removeFirst()
        }
        if unfinishedWorkers == 0 {
            return nil
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Marks `id`'s build loop as ended — it will never `send` again — and,
    /// if that was the last unfinished worker, wakes every still-waiting
    /// `receive` call with `nil`. (Safe to do unconditionally at that point:
    /// `send` only ever buffers when no one is waiting, so if a waiter
    /// exists here, the buffer is necessarily empty and there is truly
    /// nothing left to deliver.) Also re-checks whether `id`'s own sandbox
    /// is now eligible for destruction.
    func workerBuildFinished(_ id: String) async {
        workers[id, default: WorkerState()].buildFinished = true
        unfinishedWorkers -= 1
        if unfinishedWorkers == 0 {
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
            waiters.removeAll()
        }
        await destroyIfEligible(id)
    }

    /// The test lane's report that it has finished testing one clone —
    /// called exactly once per clone, on every path that finishes with one
    /// (a genuine result, a missing-from-batch fallback, a batch
    /// infrastructure failure): decrements `workerID`'s outstanding count
    /// and re-checks eligibility.
    func finishedTesting(workerID: String) async {
        if workers[workerID]?.outstandingClones ?? 0 > 0 {
            workers[workerID]?.outstandingClones -= 1
        }
        await destroyIfEligible(workerID)
    }

    /// A worker's sandbox is destroyed the instant both halves of its
    /// lifetime are done: its build loop has ended, and every clone it ever
    /// produced has been accounted for by the test lane. `destroyed` makes
    /// this idempotent — `workerBuildFinished` and `finishedTesting` can
    /// both land on the same worker becoming eligible from either side of
    /// an adversarial race, and only one of them may actually destroy it.
    private func destroyIfEligible(_ id: String) async {
        guard var state = workers[id],
              state.buildFinished, state.outstandingClones == 0, !state.destroyed,
              let sandbox = state.sandbox
        else { return }
        state.destroyed = true
        workers[id] = state
        try? await workspaces.destroySandbox(at: sandbox)
    }
}
