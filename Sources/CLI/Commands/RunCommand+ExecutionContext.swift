import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel

/// Run setup for `RunCommand`: everything between lock acquisition and the
/// first mutant executing.
///
/// Moved verbatim out of `RunCommand.swift` (which sat 5 lines over this
/// project's `file_length` limit) following the same convention as
/// `RunCommand+DependencyResolutionPreflight.swift` and
/// `RunCommand+Reports.swift`: an `extension RunCommand` in its own file,
/// purely for size. Members that were `private` in `RunCommand.swift` are
/// `internal` here for exactly that reason — their callers (`run()`,
/// `runAfterSimulatorPoolProvisioned`) live in `RunCommand.swift` — while
/// members that were already `internal` are unchanged.
extension RunCommand {
    /// `settings.execution` alongside the configuration exactly as
    /// loaded/overridden before `ExecutionProfileSupport.resolveProfile`
    /// may have resolved `execution.profile` into concrete field values —
    /// bundled into one parameter (rather than adding a second bare
    /// `Configuration` parameter to `runAfterSimulatorPoolProvisioned`/
    /// `prepareRunExecutionContext`, which would push both past this
    /// project's `function_parameter_count` lint threshold) so
    /// `PlanCompatibilityValidator.check` — the one caller that needs the
    /// pre-resolution shape — can reach it without every other caller
    /// having to thread through a value it never uses. See
    /// `settingsAsConfigured`'s own comment in `run()` for why the
    /// distinction matters.
    struct RunConfiguration {
        let resolved: Configuration
        let asConfigured: Configuration
    }

    /// Acquires `RunIsolationLock` for this run and returns the lock root
    /// `run()` also needs for `ResourceSnapshot.capture(lockRoot:)` right
    /// afterward — pulled out of `run()` itself purely to keep that
    /// already-large function's own body under this project's
    /// `function_body_length` limit.
    ///
    /// Independent MutantKit processes are not allowed to compete for the
    /// same project/destination. Real-project validation demonstrated that
    /// severe resource contention and shared simulator pressure can change
    /// a mutant's observable failure mode (crash vs timeout), which
    /// changes scoring if the two processes are allowed to interfere.
    /// Internal workers remain allowed: they share this one owning process
    /// and therefore this one lock.
    ///
    /// Acquired before simulator preparation, not after: a codex review
    /// found the original ordering booted/prepared the simulator *before*
    /// this lock, so two independent processes racing for the same
    /// destination could both boot/prepare it concurrently — CoreSimulator
    /// contention, one process's environment changes bleeding into the
    /// other's — before either noticed the collision. Lock first means a
    /// losing process fails here, before it has touched the simulator at
    /// all.
    ///
    /// Keyed on the *resolved* destination, not the raw config string: two
    /// `mutantkit.yml`s that spell the same physical simulator differently
    /// — destination unset (implicit "auto") in one, an explicit
    /// `platform=iOS Simulator,name=iPhone 17 Pro` in the other, both
    /// resolving to the same booted device — would otherwise take
    /// different lock keys and race that one simulator concurrently,
    /// exactly what this lock exists to prevent. `resolvedDestination`
    /// already pins that answer once, before `run()` calls this (see
    /// `AppleAdapterFactory.resolve`); reusing it here means "same device"
    /// and "same lock key" are the same fact, not two facts that can drift
    /// apart.
    static func acquireRunLock(
        root: URL, resolution: AppleAdapterFactory.Resolution, configuredDestination: String?, runDirectory: URL
    ) throws -> (lock: RunIsolationLock, lockRoot: URL) {
        let destinationIdentity = Self.lockIdentity(for: resolution.adapter, configuredDestination: configuredDestination)
        let lockRoot = runDirectory.appendingPathComponent("run-locks")
        let lock = try RunIsolationLock.acquire(projectRoot: root, lockRoot: lockRoot, destination: destinationIdentity)
        return (lock, lockRoot)
    }

    /// The outcome of `provisionSimulatorWorkerPoolIfNeeded`: a
    /// (possibly-unchanged) `Resolution` to use for the rest of the run,
    /// and the cleanup to run when it ends, whichever way it ends.
    /// `cleanup` is always safe to call — a no-op when nothing was ever
    /// provisioned.
    struct SimulatorWorkerPoolProvision {
        let resolution: AppleAdapterFactory.Resolution
        let cleanup: @Sendable () async -> Void
    }

    /// Provisions one real simulator per worker — `execution.simulatorPool:
    /// true`'s whole effect — or leaves `resolution` untouched when the
    /// feature is off, inapplicable to this run's configuration, or fails.
    ///
    /// Deliberately narrow eligibility (see `ExecutionSettings
    /// .simulatorPool`'s own doc comment for the full reasoning): only an
    /// `XcodeBuildProjectAdapter` with a resolved simulator device, only
    /// `incrementalBuild: true` with `testBatchSize` unset (the one
    /// execution shape this has actually been benchmarked against —
    /// per-worker persistent sandboxes give a stable identity to key a
    /// device assignment on; batched/pipelined execution's single shared
    /// test lane does not), only `resolvedWorkerCount() > 1` (nothing to
    /// parallelize otherwise).
    static func provisionSimulatorWorkerPoolIfNeeded(
        resolution: AppleAdapterFactory.Resolution,
        configuration: Configuration,
        projectRoot: URL
    ) async -> SimulatorWorkerPoolProvision {
        let workers = configuration.execution.resolvedWorkerCount()
        guard configuration.execution.simulatorPool,
              configuration.execution.strategy == .isolated,
              configuration.execution.incrementalBuild,
              configuration.execution.testBatchSize == nil,
              workers > 1,
              let projectAdapter = resolution.adapter as? XcodeBuildProjectAdapter,
              let baseDevice = projectAdapter.resolvedDestination?.device
        else {
            return SimulatorWorkerPoolProvision(resolution: resolution, cleanup: {})
        }

        // A fresh pool instance is fine here even though `projectAdapter`
        // owns its own, separate one internally: provisioning only ever
        // lists/clones/boots/deletes real `simctl` devices, which is
        // global machine state every `SimulatorPool` instance observes
        // identically — the exclusive-*leasing* invariant `SimulatorPool`
        // otherwise guarantees is a property of one actor instance's own
        // in-memory bookkeeping, not something provisioning needs at all
        // (nothing here is leased).
        let provisioningPool = SimulatorPool(workingDirectory: projectRoot)
        let orphans = await provisioningPool.cleanupOrphanClones()
        if !orphans.isEmpty {
            print("Simulator pool: cleaned up \(orphans.count) orphaned clone(s) left by a previous interrupted run.")
        }

        let devices: [SimulatorDevice]
        do {
            devices = try await provisioningPool.provisionWorkerPool(base: baseDevice, count: workers)
        } catch {
            print(
                "Simulator pool: could not provision \(workers) worker slot(s) (\(error)) — "
                    + "falling back to a single shared simulator for this run."
            )
            return SimulatorWorkerPoolProvision(resolution: resolution, cleanup: {})
        }

        let cloneCount = devices.count - 1
        print(
            cloneCount > 0
                ? "Simulator pool: \(devices.count) worker slot(s) ready (\(cloneCount) clone(s) of \(baseDevice.name))."
                : "Simulator pool: only 1 slot available; running with a single shared simulator."
        )

        var devicesByWorkspace: [String: SimulatorDevice] = [:]
        for (index, device) in devices.enumerated() {
            devicesByWorkspace[WorkspaceManager.directoryName(for: "incr-worker-\(index)")] = device
        }

        let newAdapter = AppleAdapterFactory.adapter(
            for: resolution.detection,
            configuration: configuration,
            projectRoot: projectRoot,
            resolvedDestination: projectAdapter.resolvedDestination,
            workerDevicesByWorkspace: devicesByWorkspace
        )

        return SimulatorWorkerPoolProvision(
            resolution: AppleAdapterFactory.Resolution(adapter: newAdapter, detection: resolution.detection),
            cleanup: {
                let failures = await provisioningPool.releaseWorkerPool(devices, base: baseDevice)
                if !failures.isEmpty {
                    FileHandle.standardError.write(Data(
                        "warning: could not delete simulator clone(s): \(failures.joined(separator: ", "))\n".utf8
                    ))
                }
            }
        )
    }

    /// The isolated-mode-only pieces `execute` threads into `MutationRunner`
    /// — none of these participate in schemata mode v1 (no checkpoint,
    /// coverage cache, or cross-run result cache; schemata mode does not
    /// yet support them) —
    /// bundled so `execute` itself stays within SwiftLint's parameter-count
    /// threshold.
    struct IsolatedRunOptions {
        let checkpoints: CheckpointStore
        let artifactsRoot: URL
        let coverageCache: CoverageProfileCache
        let coverageCacheKey: CoverageProfileCache.Key?
        let resultCache: MutationResultCache?
        let resultCacheDigest: String?
        let priorityStore: TestPriorityStore?
        let progress: MutationProgressReporter?
    }

    /// Everything `runAfterSimulatorPoolProvisioned` needs from the
    /// toolchain/checkpoint/cache setup below, bundled so the caller reads
    /// one destructuring assignment instead of the setup's own six local
    /// `let`s inline.
    struct RunExecutionContext {
        let toolchain: ToolchainFingerprint
        let checkpoints: CheckpointStore
        let coverageCache: CoverageProfileCache
        let coverageCacheKey: CoverageProfileCache.Key?
        let resultCache: MutationResultCache?
        let resultCacheDigest: String?
    }

    /// Computed once, up front, so both the checkpoint file name and the run
    /// itself see the identical toolchain — a probe taken after some mutants
    /// had already built would date the run by whichever mutant happened to
    /// be in flight when it ran.
    func prepareRunExecutionContext(
        root: URL, settings: RunConfiguration, loadedPlan: MutationPlan,
        resolution: AppleAdapterFactory.Resolution, runDirectory: URL, noResume: Bool
    ) async -> RunExecutionContext {
        let toolchainProbe = await ToolchainProbe.fingerprint(
            workingDirectory: root, resolvedDestination: (resolution.adapter as? XcodeBuildProjectAdapter)?.resolvedDestination
        )
        let toolchain = toolchainProbe.fingerprint

        // Against `settings.asConfigured`, not `.resolved`: `plan.json`'s
        // own `configurationHash` was written from the configuration
        // exactly as `mutantkit plan` loaded it, which never resolves
        // `execution.profile` (see `ExecutionProfileResolver`'s own doc
        // comment) — comparing against the resolved settings here would
        // report a spurious mismatch purely because a profile was chosen,
        // with the user's actual `mutantkit.yml` unchanged between
        // planning and running.
        for issue in PlanCompatibilityValidator.check(loadedPlan, against: settings.asConfigured, toolchain: toolchain) {
            print(issue.description)
        }
        let settings = settings.resolved

        // Keyed by work unit and by everything the checkpoint's cached
        // results depend on, not by work unit alone: a checkpoint exists to
        // survive an interruption *within* one attempt at a run, not to
        // survive the source, the test suite, a fixture, or the toolchain
        // changing since it was written. Folding the fingerprint into the
        // file name means a changed context is never even found, rather
        // than found and then having to be distrusted — see
        // `RunContextFingerprint`'s doc comment for why that distinction
        // mattered in practice.
        let fingerprint: RunContextFingerprint?
        do {
            fingerprint = try await RunContextProbe.compute(
                projectRoot: root,
                configuration: settings,
                toolchain: toolchain,
                workUnitID: loadedPlan.workUnitID,
                toolchainCacheIdentityComplete: toolchainProbe.identityEvidenceComplete
            )
        } catch {
            print("\(error)")
            fingerprint = nil
        }

        let checkpointURL = fingerprint.map {
            runDirectory.appendingPathComponent("checkpoint-\(loadedPlan.workUnitID)-\($0.shortDigest).jsonl")
        } ?? runDirectory.appendingPathComponent("checkpoint-\(loadedPlan.workUnitID)-unfingerprinted.jsonl")
        if noResume || fingerprint == nil {
            try? FileManager.default.removeItem(at: checkpointURL)
        }
        let verificationPolicy = MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: settings.execution.retestKilledMutants,
            confirmCrashKills: settings.execution.confirmCrashKills,
            confirmTimedOutMutants: settings.execution.confirmTimedOutMutants
        )
        let checkpoints = CheckpointStore(url: checkpointURL, policy: verificationPolicy)
        let alreadyDone = (try? await checkpoints.completedIDs(plan: loadedPlan).count) ?? 0
        if alreadyDone > 0 {
            print("Resuming: \(alreadyDone) of \(loadedPlan.mutations.count) mutants already recorded.")
        }

        // Per-test coverage attribution is the single most expensive baseline
        // cost on a real project and also the most stable across iterations:
        // it depends on the source tree and test suite, not on which mutants
        // are planned. The cache persists the measured attribution keyed by a
        // digest of those inputs (see `RunContextProbe.computeContextDigest`),
        // so the second run of an unchanged project skips the profiling pass
        // entirely. Like the checkpoint, the cache is best-effort — a digest
        // computation failure means coverage is re-measured, not a failed run.
        let coverageCacheRoot = runDirectory.appendingPathComponent("coverage-cache")
        let coverageCache = CoverageProfileCache(root: coverageCacheRoot)
        let coverageCacheKey: CoverageProfileCache.Key?
        do {
            // "coverageProfileCache3": the scope of the *tool identity* this
            // digest is computed over changed too (see
            // `IdentityScope.toolIdentityComponents`) — entries keyed under
            // the previous scheme are claims this build cannot check, for the
            // same reason the previous bump gave.
            //
            // "coverageProfileCache2", not "coverageProfileCache": the
            // scope of the configuration this digest is computed over
            // changed (see `ConfigurationScope.coverageAttribution`), so
            // every pre-existing entry on disk was keyed by a scheme this
            // build no longer implements. Bumping this purpose's own tag
            // rather than the shared `v4` marker is exact — the result
            // cache's scheme is untouched, and its entries are far cheaper
            // to lose anyway.
            let digest = try await RunContextProbe.computeContextDigest(
                projectRoot: root, configuration: settings, toolchain: toolchain, purpose: "coverageProfileCache3",
                identityScope: .coverageAttribution,
                toolchainCacheIdentityComplete: toolchainProbe.identityEvidenceComplete
            )
            coverageCacheKey = CoverageProfileCache.Key(contextDigest: digest)
        } catch {
            // Printed, not swallowed: "no cache this run" is a real slowdown
            // (the per-test coverage pass is the most expensive thing a
            // baseline does), and a user staring at an unexpectedly slow run
            // deserves the reason rather than having to guess at it. The run
            // itself continues — recomputing is always correct, just slower.
            print("\(error)")
            coverageCacheKey = nil
        }

        // Cross-run result cache: a mutant whose MutationID was already
        // evaluated against an identical execution context (same source,
        // tests, toolchain, configuration) is reused without rebuilding or
        // retesting. The cache's purpose is iteration speed — a developer
        // who re-plans and re-runs pays only for the mutants that changed,
        // not the entire plan. The digest deliberately excludes the plan's
        // workUnitID so overlapping mutants across different plans hit.
        // Best-effort, like the checkpoint: a digest failure means no
        // caching, not a failed run.
        //
        // `--no-resume`'s help text promises every mutant is re-run, which a
        // user typically reaches for specifically to get a measurement that
        // is not served from anything stale — e.g. suspecting flakiness or
        // environment drift the cache's digest doesn't model. Mirroring the
        // checkpoint's own `noResume` handling above, the cache is simply
        // not constructed for this run: neither read from nor written to.
        // The on-disk cache is left alone — only this run's use of it is
        // disabled, the same way clearing the checkpoint file above never
        // touches the result cache directory.
        let resultCache: MutationResultCache?
        let resultCacheDigest: String?
        if noResume {
            resultCache = nil
            resultCacheDigest = nil
        } else {
            let resultCacheRoot = runDirectory.appendingPathComponent("result-cache")
            resultCache = MutationResultCache(root: resultCacheRoot, policy: verificationPolicy)
            // "resultCache2", not "resultCache": a codex review found that
            // stored MutationResults from before ResultClassifier required
            // proven activation for a scorable outcome (see
            // `unprovenActivation` in ResultClassifier.swift) could be
            // loaded from an on-disk cache written by an older build and
            // re-enter a score unexamined — the cache's own store-time gate
            // only checks `outcome.isCacheableResult`/`isReportable`, never
            // `activationEvidence`. Bumping the purpose tag changes the
            // digest, which misses on every pre-existing cache entry and
            // forces a fresh, correctly-gated classification instead of
            // trusting whatever an older classifier once wrote. Any future
            // change to what makes a `MutationResult` trustworthy enough to
            // cache must bump this tag again the same way, precisely
            // because the cache has no other way to know which classifier
            // version produced an entry it is being asked to reuse.
            do {
                resultCacheDigest = try await RunContextProbe.computeContextDigest(
                    projectRoot: root,
                    configuration: settings,
                    toolchain: toolchain,
                    purpose: "resultCache2",
                    toolchainCacheIdentityComplete: toolchainProbe.identityEvidenceComplete
                )
            } catch {
                // Deliberately not printed a second time. This digest and the
                // coverage one above differ only in their `purpose` tag, and
                // nothing that can fail here depends on it — the failure is
                // always the same git/filesystem problem, already reported
                // once above with the same wording. The coverage block runs
                // unconditionally, so the reason is never lost.
                resultCacheDigest = nil
            }
        }

        return RunExecutionContext(
            toolchain: toolchain, checkpoints: checkpoints, coverageCache: coverageCache,
            coverageCacheKey: coverageCacheKey, resultCache: resultCache, resultCacheDigest: resultCacheDigest
        )
    }

    /// Everything `writeManifest` needs that stays identical across
    /// `runAfterSimulatorPoolProvisioned`'s two calls to it — bundled so
    /// that function stays under this project's `function_parameter_count`
    /// limit, and so the two call sites cannot accidentally pass slightly
    /// different values for one of these by hand.
    struct ManifestWriteContext {
        let resolution: AppleAdapterFactory.Resolution
        let settings: Configuration
        let toolchain: ToolchainFingerprint
        let resourceSnapshot: ResourceSnapshot
        let simulatorPreparation: SimulatorPreparationRecord
    }

    /// Shared by `runAfterSimulatorPoolProvisioned`'s two manifest writes —
    /// before the run starts (`baselineDuration: 0`, the only value correct
    /// for a `.fixed` timeout strategy) and again once the baseline has
    /// actually measured a real duration a `.adaptive` strategy needs. Every
    /// field except `mutantTimeoutSeconds`/`startedAt` is identical between
    /// the two calls, so duplicating this inline a second time would only
    /// ever drift the two writes apart by accident, not by design.
    func writeManifest(plan: MutationPlan, context: ManifestWriteContext, baselineDuration: Double, to url: URL) {
        try? RunManifest(
            planID: plan.planID,
            workUnitID: plan.workUnitID,
            startedAt: Date(),
            resolvedDestination: (context.resolution.adapter as? XcodeBuildProjectAdapter)?.resolvedDestination,
            scheme: context.settings.project.scheme,
            testTargets: context.settings.tests.targets,
            extraTestArguments: context.settings.tests.extraArguments,
            mutantTimeoutSeconds: context.settings.timeouts.mutant.resolve(baselineDuration: baselineDuration),
            baselineTimeoutSeconds: context.settings.timeouts.baselineSeconds,
            toolchain: context.toolchain,
            configurationHash: context.settings.configurationHash,
            resourceSnapshot: context.resourceSnapshot,
            simulatorPreparation: context.simulatorPreparation
        ).write(to: url)
    }
}
