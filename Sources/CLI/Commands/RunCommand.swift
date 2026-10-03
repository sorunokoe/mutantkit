import AppleBuildAdapters
import ArgumentParser
import Foundation
import MutationExecution
import MutationModel
import Reporting

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Execute a Mutation Plan and report the results."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var overrides: OverrideOptions

    @Option(name: .long, help: "The plan to execute.")
    var plan = "plan.json"

    @Option(name: [.customLong("output"), .customShort("o")], help: "Where to write the JSON report.")
    var output: String?

    @Option(name: .long, help: "Report formats. Overrides the config file.")
    var report: [String] = []

    // Additive counterpart to `--report`: report formats *belong* to the
    // project's `mutantkit.yml` (see `--report`'s own help text above), so a
    // caller that only wants to make sure a couple of extra formats are
    // produced — CI orchestration wiring `github-actions`/`ci-summary`
    // reports on top of whatever a project already configures, say — should
    // not have to first read that config file just to avoid clobbering it.
    // `--report` keeps its existing override semantics unchanged; this is a
    // second, independent flag, not a mode switch on the first one.
    @Option(name: .long, help: "Additional report formats, appended to (and deduped against) --report/the config's reports.")
    var alsoReport: [String] = []

    @Flag(name: .long, help: "Exit non-zero if any mutant survives.")
    var failOnSurvivors = false

    @Flag(name: .long, help: "Ignore any checkpoint and re-run every mutant.")
    var noResume = false

    @Flag(name: .long, help: "Fail closed if host resource pressure (memory, load, competing simulators) looks unsafe.")
    var requireHealthyHost = false

    // Off by default so a plain, unsharded `mutantkit run` keeps recording to
    // `.mutantkit/history` exactly as it always has. Meant for one shard of a
    // sharded plan (see `mutantkit shard`/`mutantkit merge`): a shard's score
    // is a partial slice of the project, never the whole thing, and recording
    // it under the same history that `mutantkit history` shows by default
    // would misrepresent it as a whole-project result. `mutantkit merge`
    // records the real, combined number instead — see MergeCommand.
    @Flag(name: .long, help: ArgumentHelp("Skip recording this run to `.mutantkit/history`. Use for each shard of a sharded plan — "
            + "the shard's score is partial; `mutantkit merge`'s combined result is the one that reflects the whole project."))
    var noHistory = false

    func run() async throws {
        let root = common.resolvedProjectRoot
        var settings = try ConfigurationLoader.load(explicitPath: common.configPath, projectRoot: root)
        try overrides.apply(to: &settings)

        try ConfigurationPreflight.run(settings)

        settings.reports = try Self.resolvedFinalReports(configured: settings.reports, report: report, alsoReport: alsoReport)

        let planURL = URL(fileURLWithPath: plan)
        guard FileManager.default.fileExists(atPath: planURL.path) else {
            // v0.5 Stable Contracts: diagnostics go to stderr, not stdout.
            FileHandle.standardError.write(Data("No plan at \(planURL.path). Run `mutantkit plan` first.\n".utf8))
            throw ExitCode(MutantKitExit.operationalError)
        }
        let loadedPlan = try MutationPlan.decode(from: Data(contentsOf: planURL))

        var resolution = try await AppleAdapterFactory.resolve(configuration: settings, in: root)
        print("Project: \(resolution.detection.kind.rawValue) — \(resolution.detection.reason)")

        let runDirectory = root.appendingPathComponent(".mutantkit")

        // The configuration exactly as loaded/overridden, before
        // `ExecutionProfileSupport.resolveProfile` (below) may turn
        // `execution.profile: optimized`/`experimental` into concrete
        // field values. `plan.json` was written from *this* shape (`plan`
        // never resolves a profile — see `ExecutionProfileResolver`'s own
        // doc comment), so `PlanCompatibilityValidator.check` compares
        // against this, not the resolved settings the run actually
        // executes with: comparing against the resolved settings would
        // report a spurious `plan.configurationHash` mismatch purely
        // because a profile was chosen, with the user's actual
        // `mutantkit.yml` completely unchanged between planning and
        // running.
        let settingsAsConfigured = settings

        // Independent MutantKit processes are not allowed to compete for the same
        // project/destination — see `Self.acquireRunLock`'s own doc comment for
        // why, and for the exact locking rule (pulled out of this already-large
        // function so it stays testable and under this project's own line-count
        // limits, not because the reasoning belongs anywhere else).
        let lockAcquisition = try Self.acquireRunLock(
            root: root, resolution: resolution, configuredDestination: settings.project.destination, runDirectory: runDirectory
        )
        let runLock = lockAcquisition.lock
        defer { runLock.release() }

        // See `ExecutionProfileSupport.resolveProfile`'s own doc comment
        // for why this now runs *after* lock acquisition, not before: a
        // run that is about to lose this lock race should fail here,
        // before doing any other work — including whatever a future
        // `ProjectExecutionCharacteristics` might need to probe — not only
        // before simulator preparation. Still runs before simulator
        // preparation and worker-pool provisioning, which its own doc
        // comment requires.
        if let statusLine = await ExecutionProfileSupport.resolveProfile(
            settings: &settings, plan: loadedPlan, resolution: resolution
        ) { print(statusLine) }

        // After the lock, not before: this run's own lock file is on disk by
        // now, so `runLockFilesPresent` counting one is "as expected, solo,"
        // not a false "nothing is locked" taken before this run committed to
        // anything.
        let resourceSnapshot = ResourceSnapshot.capture(lockRoot: lockAcquisition.lockRoot)

        // Memory/load only, and before simulator preparation: the same codex
        // review that moved the lock up front found this preflight ran only
        // *after* the simulator was already booted, so a host too low on
        // memory to safely run at all would still pay the cost of booting a
        // simulator before `--require-healthy-host` ever got a chance to
        // fail closed. Booted-simulator contention (necessarily a
        // post-preparation question — see `diagnoseSimulators` below) is
        // checked separately, once preparation has actually run.
        let hostOnlyItems = HostResourcePreflight.diagnoseHost(
            snapshot: resourceSnapshot,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            availableMemoryBytes: HostResourcePreflight.availableMemoryBytes()
        )
        for item in hostOnlyItems where item.status != .ok {
            print("! \(item.name): \(item.detail)")
            if let remedy = item.remedy { print("  └─ \(remedy)") }
        }
        if requireHealthyHost, hostOnlyItems.contains(where: { $0.status != .ok }) {
            // v0.5 Stable Contracts: diagnostics go to stderr, not stdout.
            FileHandle.standardError.write(Data(
                "Failing closed before the baseline: --require-healthy-host was set and the host does not look healthy.\n".utf8
            ))
            throw ExitCode(MutantKitExit.operationalError)
        }

        // Best-effort, once per run: `SimulatorPool` boots the resolved
        // destination and waits for `simctl bootstatus` to report it truly
        // ready, so the first `xcodebuild` invocation does not pay the
        // cold-boot tax or hit the CoreSimulator race (SBMainWorkspace
        // refusing a launch as "Busy") a cold back-to-back install was
        // found to hit. No-op for non-simulator destinations.
        //
        // The outcome is recorded, not swallowed: MutantKit is fail-closed,
        // and a simulator that cannot pass `bootstatus` is a broken
        // environment that would otherwise surface mid-run as a stream of
        // `.infrastructureFailure` verdicts. Stopping before the baseline —
        // only when this run actually resolved to a simulator — keeps that
        // failure cheap and its cause obvious. Warm (`alreadyBooted`) and
        // cold (`prepared`) outcomes are logged and persisted to the
        // `RunManifest` for `--replay`.
        let simulatorPreparation = await resolution.adapter.prepareSimulatorForRun()
        switch simulatorPreparation.outcome {
        case .notApplicable:
            break
        case .alreadyBooted, .prepared:
            print("Simulator ready (\(simulatorPreparation.outcome.rawValue)): \(simulatorPreparation.name ?? "unknown device").")
        case .failed:
            try Self.failClosedForSimulatorPreparationFailure(simulatorPreparation)
        }

        // Warn-only by default — the same signal `doctor` reports, checked
        // again here because a machine that looked fine at `doctor` time can
        // have changed by the time a corpus run actually starts. Fails
        // closed only when explicitly opted into: the corpus runner is the
        // one caller that has already decided a bad reading here should
        // abort before hours of runtime are spent on results a bad host
        // would make indistinguishable from a real finding.
        let simulatorApplicable = simulatorPreparation.outcome != .notApplicable
        let simulatorItems = HostResourcePreflight.diagnoseSimulators(
            bootedSimulatorCount: simulatorApplicable ? await HostResourcePreflight.bootedSimulatorCount() : nil,
            simulatorApplicable: simulatorApplicable
        )
        for item in simulatorItems where item.status != .ok {
            print("! \(item.name): \(item.detail)")
            if let remedy = item.remedy { print("  └─ \(remedy)") }
        }
        if requireHealthyHost, simulatorItems.contains(where: { $0.status != .ok }) {
            // v0.5 Stable Contracts: diagnostics go to stderr, not stdout.
            FileHandle.standardError.write(Data(
                "Failing closed before the baseline: --require-healthy-host was set and the host does not look healthy.\n".utf8
            ))
            throw ExitCode(MutantKitExit.operationalError)
        }

        // Simulator worker pool: one real simulator per worker instead of
        // every worker contending for the single destination
        // `simulatorPreparation` just verified. Provisioning failure is
        // never fail-closed here — this is a performance opt-in, not a
        // correctness requirement, so a failure prints a clear message and
        // the run proceeds with today's single-shared-device behavior
        // rather than aborting a run the user otherwise asked for.
        let poolProvision = await Self.provisionSimulatorWorkerPoolIfNeeded(
            resolution: resolution, configuration: settings, projectRoot: root
        )
        resolution = poolProvision.resolution
        // `do`/`catch` around the rest of this function, not a `defer`:
        // `DispatchSemaphore.wait()` is unavailable from an async context
        // (the compiler rejects exactly the sync/async bridge a `defer`
        // would otherwise need here), so cleanup must be an explicit
        // `await` on every exit path instead — one at the end of the `do`
        // block for the success path, one in `catch` for every thrown
        // error (the several early `throw ExitCode(...)` calls below
        // included, since they are ordinary thrown errors from this `do`
        // block's point of view).
        do {
            try await runAfterSimulatorPoolProvisioned(PostProvisioningInputs(
                root: root, settings: RunConfiguration(resolved: settings, asConfigured: settingsAsConfigured),
                loadedPlan: loadedPlan, resolution: resolution,
                runDirectory: runDirectory, resourceSnapshot: resourceSnapshot, simulatorPreparation: simulatorPreparation
            ))
            await poolProvision.cleanup()
        } catch {
            await poolProvision.cleanup()
            throw error
        }
    }

    /// v0.5 Stable Contracts: diagnostics go to stderr, not stdout — both
    /// lines here are the failure report itself (why the simulator was not
    /// ready, and the consequence of failing closed), not separate success
    /// output, so both move together. Pulled out of `run()` purely to keep
    /// that function under this project's `function_body_length` limit, the
    /// same motive as `acquireRunLock`/`PostProvisioningInputs` nearby.
    private static func failClosedForSimulatorPreparationFailure(_ preparation: SimulatorPreparationRecord) throws -> Never {
        FileHandle.standardError.write(Data(
            "Simulator \(preparation.name ?? "(unknown)") did not pass bootstatus: \(preparation.detail ?? "unknown failure").\n".utf8
        ))
        FileHandle.standardError.write(Data(
            ("Failing closed before the baseline: a simulator that cannot be verified ready "
                + "would surface as infrastructure failures mid-run.\n").utf8
        ))
        throw ExitCode(MutantKitExit.operationalError)
    }

    /// Everything `run()` does from this point on, given a (possibly
    /// simulator-pool-provisioned) `resolution` — split out purely so the
    /// simulator-pool cleanup above can wrap it in a single `do`/`catch`
    /// without re-indenting the whole rest of an already-large function.
    /// An instance method, not `static`, so every bare `output`/`report`/
    /// `failOnSurvivors`/`noResume`/`noHistory`/`common`/`overrides`
    /// reference already inside this body keeps resolving as `self.x`
    /// exactly as it did before the extraction.
    /// Bundles `runAfterSimulatorPoolProvisioned`'s inputs into one value so
    /// the function stays within this project's `function_parameter_count`
    /// limit — the same motive as `ManifestWriteContext`/`IsolatedRunOptions`
    /// elsewhere in this command. Declared here, next to its only caller
    /// and callee, rather than in `RunCommand+ExecutionContext.swift` with
    /// the other bundles: those group a callee's own needs, this one groups
    /// a call boundary both sides share.
    private struct PostProvisioningInputs {
        let root: URL
        let settings: RunConfiguration
        let loadedPlan: MutationPlan
        let resolution: AppleAdapterFactory.Resolution
        let runDirectory: URL
        let resourceSnapshot: ResourceSnapshot
        let simulatorPreparation: SimulatorPreparationRecord
    }

    private func runAfterSimulatorPoolProvisioned(_ inputs: PostProvisioningInputs) async throws {
        let root = inputs.root
        let settings = inputs.settings
        let loadedPlan = inputs.loadedPlan
        let resolution = inputs.resolution
        let runDirectory = inputs.runDirectory
        let resourceSnapshot = inputs.resourceSnapshot
        let simulatorPreparation = inputs.simulatorPreparation
        let scratch = runDirectory.appendingPathComponent("sandboxes")
        let artifacts = runDirectory.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)

        let priorityStoreURL = runDirectory.appendingPathComponent("test-priority.json")
        let (testAdapter, runnerPriorityStore) = Self.resolveTestAdapter(
            settings.resolved, base: resolution.adapter.test, priorityStoreURL: priorityStoreURL
        )

        try await Self.resolveDependenciesForConfirmationRetestIfNeeded(
            settings.resolved, testAdapter: testAdapter, root: root
        )

        let executionContext = await prepareRunExecutionContext(
            root: root, settings: settings, loadedPlan: loadedPlan, resolution: resolution, runDirectory: runDirectory, noResume: noResume
        )
        let toolchain = executionContext.toolchain
        let checkpoints = executionContext.checkpoints
        let coverageCache = executionContext.coverageCache
        let coverageCacheKey = executionContext.coverageCacheKey
        let resultCache = executionContext.resultCache
        let resultCacheDigest = executionContext.resultCacheDigest

        // Deliberately not `sources.exclude`: that governs which files are
        // *mutated*, not which files a sandbox needs to build. Copying build
        // state is actively harmful — SwiftPM records absolute paths in `.build`,
        // so a copy of it at a new path fails before it compiles anything.
        let workspaces = try WorkspaceManager(
            projectRoot: root,
            scratchRoot: scratch,
            cleanSubtreeCloning: settings.resolved.execution.cleanSubtreeCloning,
            linkSiblings: settings.resolved.project.linkSiblings ?? []
        )
        if await workspaces.supportsAPFSClone() {
            print("Sandboxes: APFS clone (copy-on-write)")
        } else {
            print("Sandboxes: plain copy — this volume does not support cloning, so runs will be slower")
        }

        print("Running \(loadedPlan.mutations.count) mutant(s) with \(settings.resolved.execution.resolvedWorkerCount()) worker(s)…\n")

        // Written before the run starts, not after: a manifest is a record of
        // what this run is *about* to do, and a run that dies partway
        // through (a timeout on the outer process, a crash, `^C`) should
        // still leave behind an accurate account of the destination and
        // timeout it committed to, for `--replay` to use against whichever
        // mutants did get checkpointed. Best-effort — a manifest write
        // failure is not a reason to fail the run itself.
        let manifestURL = RunManifest.url(runDirectory: runDirectory, workUnitID: loadedPlan.workUnitID)
        let manifestContext = ManifestWriteContext(
            resolution: resolution, settings: settings.resolved, toolchain: toolchain,
            resourceSnapshot: resourceSnapshot, simulatorPreparation: simulatorPreparation
        )
        writeManifest(plan: loadedPlan, context: manifestContext, baselineDuration: 0, to: manifestURL)

        let report = try await Self.execute(
            strategy: settings.resolved.execution.strategy,
            context: SchemataRunOrchestration.Context(
                plan: loadedPlan, configuration: settings.resolved, projectRoot: root,
                adapter: resolution.adapter, testAdapter: testAdapter, toolchain: toolchain,
                // Deliberately the same two values passed to
                // `IsolatedRunOptions` below, not a second cache instance or
                // a second digest computation: whichever backend measures
                // the attribution first, the other one reuses it.
                coverageCache: coverageCache, coverageCacheKey: coverageCacheKey
            ),
            workspaces: workspaces, runDirectory: runDirectory,
            isolatedOptions: IsolatedRunOptions(
                checkpoints: checkpoints, artifactsRoot: artifacts, coverageCache: coverageCache, coverageCacheKey: coverageCacheKey,
                resultCache: resultCache, resultCacheDigest: resultCacheDigest, priorityStore: runnerPriorityStore,
                // Labelled, and only ever handed to the `.isolated` branch of
                // `execute` below, where the whole plan really is what this
                // one runner will work through. A schemata run's own
                // isolated-fallback portion gets a separate reporter totalled
                // on the *fallback* plan (see `runFallbackPortion`) — this
                // total would stall short of completion there, since most of
                // the plan never reaches that portion.
                progress: MutationProgressReporter(total: loadedPlan.mutations.count, label: "mutants")
            )
        )

        // Rewritten with the *measured* baseline-adaptive timeout once the
        // baseline has actually run — the pre-run write above used
        // `baselineDuration: 0` as a placeholder for a strategy that scales
        // with it, which is only ever right for `.fixed`. `--replay` needs
        // the number every mutant in this run was actually held to.
        if report.baseline.passed {
            writeManifest(plan: loadedPlan, context: manifestContext, baselineDuration: report.baseline.durationSeconds, to: manifestURL)
        }

        try emit(report, settings: settings.resolved, runDirectory: runDirectory)
        // Gate 3 diagnostic instrumentation only (see
        // `GateTimingRecorder`'s own doc comment) — every other run leaves
        // this env var unset and pays nothing beyond the spans' already-
        // negligible recording cost.
        if let timingOutputPath = ProcessInfo.processInfo.environment["MUTANTKIT_GATE3_TIMING_OUTPUT"] {
            try await GateTimingRecorder.shared.write(to: URL(fileURLWithPath: timingOutputPath))
            print("Wrote \(timingOutputPath) (Gate 3 timing spans)")
        }
        if !noHistory {
            Self.recordHistory(report, to: RunHistoryStore(root: runDirectory.appendingPathComponent("history")))
        }

        // Integrity outranks everything: a run whose invariants did not reconcile
        // has no score to threshold against, so there is nothing to compare and
        // reporting a survivor count from it would be a claim we cannot back.
        guard report.integrity.passed else {
            throw ExitCode(MutantKitExit.integrityFailure)
        }
        if failOnSurvivors, (report.score?.survived ?? 0) > 0 {
            throw ExitCode(MutantKitExit.survivorsFound)
        }
    }

    /// Dispatches to the existing, unmodified `MutationRunner` for
    /// `.isolated` or to `SchemataRunOrchestration` for `.schemata` —
    /// pulled out of `run()` itself so that already-large function's own
    /// complexity does not keep growing every time a new execution
    /// strategy is added.
    private static func execute(
        strategy: ExecutionMode, context: SchemataRunOrchestration.Context, workspaces: WorkspaceManager,
        runDirectory: URL, isolatedOptions: IsolatedRunOptions
    ) async throws -> RunReport {
        switch strategy {
        case .isolated:
            return try await MutationRunner(
                plan: context.plan,
                configuration: context.configuration,
                projectRoot: context.projectRoot,
                build: context.adapter.build,
                test: context.testAdapter,
                workspaces: workspaces,
                checkpoints: isolatedOptions.checkpoints,
                artifactsRoot: isolatedOptions.artifactsRoot,
                toolchain: context.toolchain,
                coverageCache: isolatedOptions.coverageCache,
                coverageCacheKey: isolatedOptions.coverageCacheKey,
                resultCache: isolatedOptions.resultCache,
                resultCacheDigest: isolatedOptions.resultCacheDigest,
                priorityStore: isolatedOptions.priorityStore,
                progress: isolatedOptions.progress
            ).run()
        case .schemata:
            // A separate scratch subdirectory from the isolated-fallback
            // pass's `workspaces` so the two passes' sandboxes never
            // collide mid-run.
            let schemataScratch = runDirectory.appendingPathComponent("schemata-sandboxes")
            let schemataWorkspaces = try WorkspaceManager(
                projectRoot: context.projectRoot,
                scratchRoot: schemataScratch,
                cleanSubtreeCloning: context.configuration.execution.cleanSubtreeCloning,
                linkSiblings: context.configuration.project.linkSiblings ?? []
            )
            // No timeout argument: this call site used to pass
            // `timeouts.baselineSeconds` as the *only* limit, which
            // `SchemataMutationRunner` then applied to every per-mutant token
            // run as well as to the baseline — giving a hanging schemata
            // mutant the whole suite's budget (600 s by default) where
            // isolated mode correctly spends `timeouts.mutant`. The runner
            // now reads `context.configuration.timeouts` itself and resolves
            // each limit separately.
            return try await SchemataRunOrchestration.run(
                context: context, workspaces: workspaces, schemataWorkspaces: schemataWorkspaces
            )
        }
    }
}
