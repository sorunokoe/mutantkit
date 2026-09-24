import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend

/// Builds and tests a Swift package on the host with `swift build` / `swift test`.
///
/// Only for packages that actually have a host slice. A package declaring only
/// iOS cannot be tested this way — it has no macOS platform to link against, and
/// forcing it through here is what makes `import UIKit` fail with an error that
/// blames the user's code. `ProjectDetector` is what keeps those packages away
/// from this adapter.
public struct SwiftPackageMacOSAdapter: Sendable {
    let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Where SwiftPM leaves the test bundles.
    func productsDirectory(in workspace: URL) -> URL {
        workspace.appendingPathComponent(".build/debug", isDirectory: true)
    }

    /// Where the package under test actually lives inside `workspace` —
    /// `workspace` itself when `project.path` is unset, empty, `"."`, or
    /// absolute; `workspace` plus that (necessarily relative) path
    /// otherwise.
    ///
    /// `project.path` is documented (see `SwiftPMLiveSourceResolution`'s own
    /// "package lives elsewhere" comment, and `diagnose()` below) as the
    /// supported way to point mutantkit at a package that is not itself at
    /// `--project-root` — a monorepo umbrella one level up from the real
    /// package, most plausibly, so that package's own local
    /// `.package(path:)` siblings are cloned into the sandbox alongside it
    /// (`WorkspaceManager.createSandbox` clones `--project-root`'s entire
    /// contents verbatim, siblings included). Plan-time discovery already
    /// honors this (`SwiftPMLiveSourceResolution.packageLocation`'s
    /// `root.appendingPathComponent(path)`) — this mirrors that exact
    /// resolution so the actual sandboxed `swift build`/`swift test`
    /// invocation runs at the same place plan-time already decided the
    /// package lives, instead of at the sandbox's own root (which has no
    /// `Package.swift` of its own when `project.path` is set to a
    /// subdirectory).
    ///
    /// Absolute paths are left unresolved, deliberately: `workspace` here is
    /// always a sandbox clone of `--project-root`'s own contents, and an
    /// absolute `project.path` cannot express "somewhere inside this
    /// sandbox" the way a relative one does — the pre-existing, unresolved
    /// behavior is preserved for that case rather than guessed at.
    func resolvedWorkspace(_ workspace: URL) -> URL {
        guard let path = configuration.project.path, !path.isEmpty, path != "." else { return workspace }
        guard !path.hasPrefix("/") else { return workspace }
        return workspace.appendingPathComponent(path)
    }
}

// MARK: - Build

extension SwiftPackageMacOSAdapter: BuildAdapter {
    public func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        try await buildWithSharedCacheRecovery(in: workspace)
    }

    /// The mutated source is already on disk in this workspace, so a mutant build
    /// is the same command as the baseline's.
    public func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        try await buildWithSharedCacheRecovery(in: workspace)
    }

    /// Real build, plus -- only when `sharedModuleCache` is on and the
    /// failure's own captured output gives *specific, positive evidence*
    /// that this build's own shared cache directory is implicated -- one
    /// automatic retry against a freshly emptied cache before giving up.
    ///
    /// This is a level up from `SharedModuleCacheTests
    /// .corruptedCacheEntryStillBuildsCorrectly`: that test already proves
    /// Clang detects and recompiles an individual corrupted cache entry
    /// in-place, without ever failing the build at all. This exists for the
    /// build that fails anyway -- confirmed reproducible, not hypothetical:
    /// making the resolved cache directory itself unwritable before a cold
    /// build (this session's own real reproduction, since Clang's per-file
    /// corruption recovery already covers a damaged-but-writable `.pcm`)
    /// makes `swift build` fail with `<unknown>:0: error: error opening
    /// '<cache-path>/Swift-<hash>.swiftmodule' for output: ...: Permission
    /// denied` -- the cache path itself, verbatim, inside the diagnostic.
    ///
    /// The heuristic below (`isLikelySharedModuleCacheCorruption`) is built
    /// from that same real reproduction, cross-checked against the equally
    /// real negative: a genuine mutation-caused compile error
    /// (`Sources/Calc/Calc.swift:3:59: error: cannot find operator '+++' in
    /// scope`, reproduced the same session) never once mentions the module
    /// cache path anywhere in its output -- compiler diagnostics for a
    /// *source* problem name the source file, never the cache directory.
    /// That gives a genuinely specific, evidence-based signal instead of a
    /// guess, and is exactly why this must never degrade into "retry every
    /// failure once": doing that would silently retry a real, mutation-
    /// caused build failure and either mask it behind a coincidentally-
    /// successful retry (a false, hidden non-failure) or double the wall
    /// clock every unviable mutant already costs, for zero benefit. See
    /// `isLikelySharedModuleCacheCorruption`'s own doc comment for the
    /// exact guard this rests on.
    ///
    /// Retries at most once: a second cache-implicated failure after an
    /// already-fresh, already-emptied cache is not cache staleness by this
    /// heuristic's own definition (a fresh cache cannot be *stale*), so the
    /// retry's own failure -- whatever it is -- propagates as the real,
    /// final answer rather than looping.
    private func buildWithSharedCacheRecovery(in workspace: URL) async throws -> BuildArtifact {
        guard let cachePath = await resolvedModuleCachePath(for: workspace) else {
            return try await build(in: workspace, extraArguments: [])
        }
        let extraArguments = Self.moduleCacheArguments(for: cachePath)

        do {
            return try await build(in: workspace, extraArguments: extraArguments)
        } catch let failure as BuildFailure {
            guard Self.isLikelySharedModuleCacheCorruption(failure, cachePath: cachePath) else { throw failure }
            await SharedModuleCacheNamespace.shared.forceRemove(cachePath)
            return try await build(in: workspace, extraArguments: extraArguments)
        }
    }

    /// Whether `failure` gives specific, positive evidence that the shared
    /// module cache directory at `cachePath` -- this build's own, already
    /// resolved -- is what actually broke the build, as opposed to an
    /// unrelated infrastructure problem, a generic compiler crash, or
    /// (never eligible at all) a real compile error in the mutated source.
    /// See `buildWithSharedCacheRecovery`'s own doc comment for the real
    /// reproduction behind both halves of this guard.
    ///
    /// - `failure.kind == .compilationError` is excluded unconditionally,
    ///   first, before anything else is even considered. `BuildClassifier`
    ///   only reaches that kind by finding a real `file.swift:LINE:COL:
    ///   error:` diagnostic in the output (`BuildClassifier.firstDiagnostic`)
    ///   -- i.e. it has already proven the mutated *source* is what's wrong.
    ///   The shared cache holds only precompiled system modules, never
    ///   project code (`ExecutionSettings.sharedModuleCache`'s own safety
    ///   case), so it has nothing to do with a compile error and must never
    ///   be blamed for one -- this is the guard that makes "a real mutant
    ///   build failure retried into a silent pass" structurally impossible
    ///   here, not merely unlikely.
    /// - `failure.kind == .timedOut` is excluded too, deliberately: a hang
    ///   prints no diagnostic at all while it is stuck, so there is no
    ///   positive evidence available to check either way, and retrying an
    ///   already-timed-out build doubles the wall-clock cost of a build
    ///   that may simply need real investigation. Absence of evidence is
    ///   treated as absence of grounds to retry, per this task's own
    ///   "default to NOT treating an ambiguous failure as corruption".
    /// - Only `.infrastructure` failures are even considered, and only when
    ///   `failure.output` contains the compiler's own `error opening
    ///   '<path>` diagnostic (Clang/Swift's shared "could not open this
    ///   file" template -- confirmed against this machine's real
    ///   `swift-frontend` strings table, which prints it as `error opening
    ///   '%0' for output: %1` and `error opening '%0': %1`) naming a path
    ///   *inside* this build's own resolved `cachePath`. That is real,
    ///   positive evidence the cache directory itself is what the compiler
    ///   failed to read or write, not merely that the cache path was
    ///   mentioned somewhere in the output.
    ///
    ///   Bare-substring matching on `cachePath.path` alone -- this
    ///   heuristic's original shape -- is NOT sufficient and must never come
    ///   back: `-module-cache-path <cachePath>` is one of the arguments on
    ///   every single build's own command line once `sharedModuleCache` is
    ///   on, and a crashing `swift-frontend` unconditionally echoes its full
    ///   argument list (`Stack dump: 0. Program arguments: ...`) as part of
    ///   its crash report, regardless of what actually crashed it. Verified
    ///   live, the same way the false positive was originally found: forcing
    ///   a generic, cache-unrelated crash (`-Xfrontend
    ///   -debug-crash-after-parse`) with the shared cache flag on still
    ///   prints `-module-cache-path <path>` verbatim inside that crash's own
    ///   `Program arguments:` line -- so requiring only "the path appears in
    ///   the output" made *every* frontend crash look like cache corruption,
    ///   not just ones actually caused by it. That same captured crash
    ///   output contains no `error opening '` anywhere, which is exactly the
    ///   distinction this guard now keys on: a crash's own echoed invocation
    ///   is not evidence the cache broke anything, but the compiler's own
    ///   "I tried to open a file under this path and could not" diagnostic
    ///   is.
    static func isLikelySharedModuleCacheCorruption(_ failure: BuildFailure, cachePath: URL) -> Bool {
        guard failure.kind == .infrastructure else { return false }
        return failure.output.contains("error opening '\(cachePath.path)")
    }

    /// `-Xswiftc -module-cache-path` arguments pointing this build at
    /// `cachePath` -- pure string formatting, split out from
    /// `resolvedModuleCachePath(for:)` so `buildWithSharedCacheRecovery`
    /// can build the identical argument list twice (the original attempt
    /// and, when warranted, the retry) from one already-resolved path
    /// without re-resolving or re-probing anything.
    private static func moduleCacheArguments(for cachePath: URL) -> [String] {
        ["-Xswiftc", "-module-cache-path", "-Xswiftc", cachePath.path]
    }

    /// This build's shared module cache directory -- see
    /// `SharedModuleCacheNamespace` for the real toolchain fingerprinting
    /// and once-per-run reset behind it -- or `nil` when the flag is off,
    /// meaning "today's default: a private cache nested inside this
    /// sandbox's own `.build`".
    ///
    /// Deliberately never called from `buildSchemataChunk`: the flag's
    /// safety case (every mutant needs only the module set the baseline
    /// build already warmed, because a mutation never changes an import)
    /// was checked against the isolated backend's build shape, not
    /// schemata's.
    private func resolvedModuleCachePath(for workspace: URL) async -> URL? {
        guard configuration.execution.sharedModuleCache else { return nil }
        return await SharedModuleCacheNamespace.shared.moduleCachePath(forSandbox: workspace, workingDirectory: workspace)
    }

    private func build(in rawWorkspace: URL, extraArguments: [String] = []) async throws -> BuildArtifact {
        // Resolved once, here: every use below (the process's own
        // `workingDirectory`, and `productsDirectory(in:)` for the artifact
        // this returns) must agree on where the package actually is — see
        // `resolvedWorkspace(_:)`'s own doc comment.
        let workspace = resolvedWorkspace(rawWorkspace)

        // `--build-tests` so the test bundle exists before `swift test --skip-build`
        // runs. Without it the test step would silently rebuild, and the build and
        // test timings — which drive the adaptive mutant timeout — would be wrong.
        let arguments = ["swift", "build", "--build-tests"] + extraArguments

        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcrun,
                arguments: arguments,
                workingDirectory: workspace,
                timeoutSeconds: configuration.timeouts.baselineSeconds,
                terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
            )
        } catch {
            throw BuildFailure(
                kind: .infrastructure,
                diagnosis: "Could not launch the Swift toolchain: \(error)",
                command: CommandRecording.record(
                    executable: ToolPaths.xcrun,
                    arguments: arguments,
                    workingDirectory: workspace,
                    result: nil
                ),
                output: ""
            )
        }

        let command = CommandRecording.record(
            executable: ToolPaths.xcrun,
            arguments: arguments,
            workingDirectory: workspace,
            result: result
        )

        guard result.succeeded else {
            throw BuildClassifier.failure(from: result, command: command)
        }

        let products = productsDirectory(in: workspace)
        return BuildArtifact(
            productsDirectory: products,
            productHash: TestProductHasher.hash(productsDirectory: products),
            // SwiftPM does not produce one; `swift test` needs no such handoff.
            xctestrunPath: nil,
            command: command
        )
    }

    public func diagnose() async throws -> BuildDiagnosis {
        var items: [DiagnosisItem] = []
        let workspace = URL(fileURLWithPath: configuration.project.path ?? ".")

        items.append(await Diagnostics.swiftVersion(workingDirectory: workspace))
        items.append(contentsOf: await Diagnostics.projectKind(workspace: workspace))
        items.append(Diagnostics.diskSpace(at: workspace))

        return BuildDiagnosis(items: items)
    }
}

// MARK: - Schemata build

extension SwiftPackageMacOSAdapter: SchemataBuildable {
    public func buildSchemataChunk(loweredSources: [SchemataSourceFile], in workspace: URL) async throws -> BuildArtifact {
        for source in loweredSources {
            try SchemataSourceWriter.write(source, in: workspace)
        }

        let located = try SchemataRuntimeLibraryLocator.locate(for: .macOS)
        let linkerArguments = SwiftPMLinkerInjector.extraArguments(archivePath: located.archivePath)
        return try await build(in: workspace, extraArguments: linkerArguments)
    }

    public func resolveSchemataBuildReceipt(
        for units: [SchemataCompilationUnitTargetRequest],
        artifact: BuildArtifact,
        in workspace: URL,
        context: SchemataBuildReceiptContext
    ) async throws -> SchemataBuildReceipt {
        let discovered = try SchemataBuiltImageInspection.inspect(productsDirectory: artifact.productsDirectory)
        let graph = try await SwiftPMTargetResolver.resolveDependencyGraph(projectRoot: resolvedWorkspace(workspace))

        // Keyed by the *request's own* `buildTarget` — the chunk planner's
        // already-authoritative identity — never a value this resolver
        // recomputes from the dependency graph's own `projectIdentity`.
        // The two can legitimately differ (a caller's `projectIdentity` need
        // not be `Package.swift`'s own path), and a receipt whose
        // `buildTarget` silently disagreed with what the caller requested
        // would make every later `CompilationUnitReceipt.buildTarget ==
        // request.buildTarget` lookup fail closed for the wrong reason.
        let buildTargetsByName = Dictionary(units.map { ($0.buildTarget.targetName, $0.buildTarget) }) { first, _ in first }
        let resolvedByTarget = try SwiftPMCompilationUnitImageResolver.resolve(
            targets: Set(buildTargetsByName.keys), graph: graph, discovered: discovered
        )

        var imagesByTarget: [BuildTargetIdentity: BuiltImageReceipt] = [:]
        for (targetName, image) in resolvedByTarget {
            guard let buildTarget = buildTargetsByName[targetName] else { continue }
            if imagesByTarget[buildTarget] == nil {
                imagesByTarget[buildTarget] = try BuiltImageReceipt(
                    buildTarget: buildTarget,
                    binaryPath: image.binaryPath,
                    contentHash: image.contentHash,
                    slices: image.slices
                )
            }
        }

        let compilationUnits = units.map {
            CompilationUnitReceipt(
                compilationUnitID: $0.compilationUnitID,
                sourceEmbeddingID: $0.sourceEmbeddingID,
                buildTarget: $0.buildTarget
            )
        }

        return try SchemataBuildReceipt(
            planID: context.planID,
            workUnitID: context.workUnitID,
            chunkID: context.chunkID,
            toolchainHash: context.toolchainHash,
            buildArgumentsHash: context.buildArgumentsHash,
            runtimeABIVersion: UInt32(BoolLiteralSchemataLowerer.runtimeABIVersion),
            images: Array(imagesByTarget.values),
            compilationUnits: compilationUnits
        )
    }
}

// MARK: - Test

extension SwiftPackageMacOSAdapter: TestAdapter {
    public func runBaseline(
        _ artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async throws -> TestRunResult {
        // Coverage is measured on the baseline only, once per run, then reused
        // for every mutant — see `CoverageMeasuring`. Turning the flag on here
        // means SwiftPM re-instruments the build during this test run; the
        // baseline's `productHash` was captured *before* instrumentation, so
        // every mutant is still compared against an uninstrumented reference.
        // Mutants are never built with coverage, so the comparison stays
        // apples-to-apples.
        try await runTests(
            in: workspace,
            timeoutSeconds: timeoutSeconds,
            enableCoverage: configuration.execution.measureCoverage
        )
    }

    public func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async throws -> TestRunResult {
        try await runTests(in: workspace, timeoutSeconds: timeoutSeconds, enableCoverage: false)
    }

    /// The `swift test` build-related flags for one invocation, factored out
    /// so the exact contract is unit-testable without spawning a toolchain.
    ///
    /// - `enableCoverage`: whether `--enable-code-coverage` is passed.
    /// - `skipBuild`: whether `--skip-build` is passed. `nil` reproduces the
    ///   original either/or default (skip only when coverage is off, since a
    ///   coverage-enabled run may need SwiftPM's own one-shot instrumented
    ///   rebuild); an explicit `true`/`false` overrides that default,
    ///   letting a caller that already knows the current artifact's state —
    ///   `measurePerTestCoverage`'s loop, from its second iteration on —
    ///   request both flags together.
    static func swiftTestBuildFlags(enableCoverage: Bool, skipBuild: Bool?) -> [String] {
        var flags: [String] = []

        if enableCoverage {
            flags.append("--enable-code-coverage")
        }

        if skipBuild ?? !enableCoverage {
            flags.append("--skip-build")
        }

        return flags
    }

    private func runTests(
        in rawWorkspace: URL,
        timeoutSeconds: Double,
        enableCoverage: Bool = false,
        skipBuild: Bool? = nil,
        extraEnvironment: [String: String] = [:],
        testFilters: [String]? = nil,
        reliableExpectedTestCount: Int? = nil,
        scratchPath: URL? = nil
    ) async throws -> TestRunResult {
        // Resolved exactly when this is an ordinary sandboxed run
        // (`scratchPath == nil`): a `scratchPath` call already passes an
        // explicitly-resolved `--package-path` (see `runConfirmationRetest`),
        // and re-resolving it here would join `project.path` on top a second
        // time. See `resolvedWorkspace(_:)`'s own doc comment.
        let workspace = scratchPath == nil ? resolvedWorkspace(rawWorkspace) : rawWorkspace

        // Written inside `scratchPath` when one is given (a disposable
        // confirmation clone), `workspace` otherwise -- `workspace` can now
        // be the read-only `projectRoot` (see `scratchPath` below).
        //
        // Unique per invocation, not a fixed name: `measurePerTestCoverage`'s
        // loop calls this method many times against the *same* workspace, so
        // a fixed path would be the same file on every call. An earlier
        // version of this cleared that fixed path with a `try?`-guarded
        // delete before each run — but a failed removal (permissions, a
        // locked file, anything) would silently leave the previous
        // iteration's report in place, and `classify`'s shortfall check
        // would read it as this run's own (P12-B Finding C's fail-closed
        // contract broken by exactly the failure mode meant to protect it).
        // A UUID in the filename makes that collision structurally
        // impossible instead of merely attempted — no cleanup to fail.
        let xunitOutput = (scratchPath ?? workspace).appendingPathComponent("mutantkit-xunit-\(UUID().uuidString).xml")

        // `--skip-build` because the build already happened and was already
        // classified. Letting the test step build would turn a compilation error
        // into a test failure, scoring an unviable mutant as killed.
        //
        // The baseline is the exception: `--enable-code-coverage` may force a
        // re-build with instrumentation. That rebuild is bounded and one-shot,
        // and letting SwiftPM do it inside `swift test` is simpler and more
        // reliable than re-deriving the flag's effect on `swift build`.
        //
        // `skipBuild` lets a caller that already knows the coverage-
        // instrumented artifact is current — `measurePerTestCoverage`'s loop,
        // from its second iteration on — pass both flags together. `nil`
        // reproduces the exact pre-existing either/or default: skip only when
        // coverage is off.
        var arguments = ["swift", "test"]
        arguments.append(contentsOf: Self.swiftTestBuildFlags(enableCoverage: enableCoverage, skipBuild: skipBuild))
        arguments.append(contentsOf: ["--xunit-output", xunitOutput.path])

        // `scratchPath`, when given, means `workspace` is the tool's
        // read-only `projectRoot`, standing in only for the package
        // manifest (`--package-path`); pre-built products live under
        // `scratchPath` instead, nested `<triple>/<configuration>` (`swift
        // test --scratch-path` computes that path itself, confirmed
        // empirically) — see `PackageManifestConfirmationRetesting`.
        if let scratchPath {
            arguments.append(contentsOf: ["--package-path", workspace.path, "--scratch-path", scratchPath.path])
        }

        // Opt-in only. SwiftPM writes the XCTest half of the xunit report only in
        // parallel mode, so this is the difference between having per-test counts
        // and not — but a parallel-unsafe suite flakes, and a flake during a
        // mutant's run is recorded as that mutant being killed. Losing counts is
        // visible; an inflated score is not.
        if configuration.tests.parallel {
            arguments.append("--parallel")
        }

        // `testFilters` narrows to a specific set of tests (per-test coverage
        // measurement, `TestSelecting.runMutant`'s selected-test narrowing);
        // `nil` means "no narrowing requested", which falls back to the same
        // configured target list every unnarrowed call already used.
        for filter in testFilters ?? configuration.tests.targets {
            arguments.append(contentsOf: ["--filter", filter])
        }
        arguments.append(contentsOf: configuration.tests.extraArguments)

        let result: ProcessResult
        do {
            // `extraEnvironment` merges over the ambient environment,
            // exactly the default `ProcessSupervisor.run` would otherwise
            // use on its own — this is the only difference from every
            // other call site here, and is empty (a true no-op) for both
            // `runBaseline`/`runMutant`.
            let environment = extraEnvironment.isEmpty
                ? ProcessInfo.processInfo.environment
                : ProcessInfo.processInfo.environment.merging(extraEnvironment) { _, new in new }
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcrun,
                arguments: arguments,
                workingDirectory: workspace,
                environment: environment,
                timeoutSeconds: timeoutSeconds,
                terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
            )
        } catch {
            return TestRunResult(
                status: .infrastructureFailure,
                summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcrun,
                    arguments: arguments,
                    workingDirectory: workspace,
                    result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "Could not launch the Swift toolchain: \(error)"
            )
        }

        let command = CommandRecording.record(
            executable: ToolPaths.xcrun,
            arguments: arguments,
            workingDirectory: workspace,
            result: result
        )

        return Self.classify(
            result: result, command: command, xunitOutput: xunitOutput,
            reliableExpectedTestCount: reliableExpectedTestCount
        )
    }

    static let emptySummary = TestOutcomeSummary(
        total: 0, passed: 0, failed: 0, failingTests: [], durationSeconds: nil
    )
}

// MARK: - Confirmation retest

extension SwiftPackageMacOSAdapter: PackageManifestConfirmationRetesting {
    /// `PackageManifestConfirmationRetesting.runConfirmationRetest` — see
    /// its doc comment for the full "why".
    public func runConfirmationRetest(
        _ point: MutationPoint,
        packageRoot: URL,
        productsScratchRoot: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        // `packageRoot` here is the real, unsandboxed `--project-root` (not
        // a sandbox clone), so it needs the same `project.path` join
        // `resolvedWorkspace(_:)` applies everywhere else — `runTests`
        // itself will not do this automatically, because `scratchPath`
        // (below) tells it `packageRoot` is already resolved.
        try await runTests(
            in: resolvedWorkspace(packageRoot),
            timeoutSeconds: timeoutSeconds,
            enableCoverage: false,
            testFilters: Self.testFilterArguments(for: selectedTests),
            reliableExpectedTestCount: Self.reliableExpectedCount(for: selectedTests),
            scratchPath: productsScratchRoot
        )
    }
}

// MARK: - Schemata test

extension SwiftPackageMacOSAdapter: SchemataTestable {
    /// Reuses the exact `swift test --skip-build` invocation shape
    /// `runMutant` already uses — no rebuild, no extra linker flags needed
    /// here (the chunk was already linked by `buildSchemataChunk`), just
    /// `environment` merged in so the runtime activates the requested
    /// token. Proven end to end by `SchemataSwiftPMLinkerInjectionAcceptanceTests
    /// .testBundleLinksAndActivatesWithNoManifestChange`.
    public func runSchemataToken(
        _ artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        environment: [String: String],
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        try await runTests(
            in: workspace,
            timeoutSeconds: timeoutSeconds,
            enableCoverage: false,
            extraEnvironment: environment,
            testFilters: Self.testFilterArguments(for: selectedTests),
            reliableExpectedTestCount: Self.reliableExpectedCount(for: selectedTests)
        )
    }
}

// MARK: - Coverage

extension SwiftPackageMacOSAdapter: CoverageMeasuring {
    public func readCoverage(in workspace: URL, projectRoot: URL) async -> CoverageMap? {
        // SwiftPM writes codecov JSON under `.build/<arch>/<build>/codecov/`.
        // `.build/debug` is normally a symlink to the real path; resolving it
        // is what makes the enumerator actually descend (HANDOVER §3-3).
        //
        // Resolved: this is where the build actually ran (see
        // `resolvedWorkspace(_:)`), which is where its `.build` directory
        // — and the codecov JSON under it — actually landed on disk.
        let buildDir = productsDirectory(in: resolvedWorkspace(workspace)).resolvingSymlinksInPath()
        let codecovDir = buildDir.appendingPathComponent("codecov", isDirectory: true)
        // The codecov paths are absolute and rooted at the *sandbox*, because
        // that is where the instrumented binary was built. The plan, however,
        // uses repository-relative paths, and the sandbox is a verbatim copy of
        // the project tree — so stripping the *workspace* prefix (not the
        // caller's `projectRoot`) yields the same repo-relative shape the plan
        // uses. Passing `projectRoot` here would match nothing.
        //
        // Deliberately the raw, unresolved `workspace` — not
        // `resolvedWorkspace(workspace)` — so the stripped shape keeps
        // whatever `project.path` prefix the plan itself expresses (see
        // `SwiftPMLiveSourceResolution.resolve`'s own `relativePackagePath`
        // prefixing), rather than a shape with that prefix already removed.
        return SourceCoverageReader.read(directory: codecovDir, projectRoot: workspace)
    }
}

// MARK: - Test selection

extension SwiftPackageMacOSAdapter: TestSelecting {
    /// `TestSelecting.runMutant`. An empty selection is never turned into
    /// `--filter` arguments — that would filter the run down to nothing, and
    /// a run that tested nothing must never be mistaken for one that passed.
    /// Falls back to the full configured target list, the same behaviour as
    /// `selectedTests == nil` and identical to the unparameterised
    /// `runMutant` above.
    public func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        try await runTests(
            in: workspace,
            timeoutSeconds: timeoutSeconds,
            enableCoverage: false,
            testFilters: Self.testFilterArguments(for: selectedTests),
            reliableExpectedTestCount: Self.reliableExpectedCount(for: selectedTests)
        )
    }

    /// `selectedTests` -> `swift test --filter` arguments, or `nil` for an
    /// unrestricted run — the one place that empty-means-nil normalisation
    /// (`TestSelecting`'s documented convention) is applied, shared by every
    /// call site that turns a `Set<TestIdentifier>?` into filter arguments
    /// (`TestSelecting.runMutant` above, `SchemataTestable.runSchemataToken`
    /// below) so the rule can never drift between the two.
    fileprivate static func testFilterArguments(for selectedTests: Set<TestIdentifier>?) -> [String]? {
        selectedTests.flatMap { $0.isEmpty ? nil : $0.map(\.swiftTestFilterArgument) }
    }

    /// How many tests a narrowed selection should produce, when that count
    /// can actually be trusted against SwiftPM's own `--xunit-output` — see
    /// `classify(reliableExpectedTestCount:)`. `nil` for an unrestricted run
    /// (nothing to compare against) and for any selection that includes an
    /// XCTest identifier (its own report requires `tests.parallel`, so its
    /// absence proves nothing under the default configuration); a mixed
    /// selection is left unchecked rather than guessing which half of a
    /// merged count to trust.
    fileprivate static func reliableExpectedCount(for selectedTests: Set<TestIdentifier>?) -> Int? {
        guard let selectedTests, !selectedTests.isEmpty,
              selectedTests.allSatisfy(\.isSwiftTestingShaped) else { return nil }
        return selectedTests.count
    }

    public func measurePerTestCoverage(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        await PerTestCoverageProfileAttempt.resolve(
            fast: { await measurePerTestCoverageFast(artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds) },
            serial: { await measurePerTestCoverageSerial(artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds) }
        )
    }

    private func measurePerTestCoverageFast(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageProfileAttempt {
        .unavailable(reason: "no fast per-test coverage backend is implemented yet")
    }

    /// Runs every test `swift test list` reports, one at a time, with
    /// coverage enabled, against the artifact already built for the
    /// baseline — no separate coverage build step: `swift test
    /// --enable-code-coverage` re-instruments as a side effect the same way
    /// `runBaseline`'s own coverage pass already relies on (see its doc
    /// comment above), so only the first of these per-test invocations needs
    /// to pay for that one-shot rebuild. Every later one passes `skipBuild:
    /// true` explicitly — sources never change between iterations of this
    /// loop, so there is nothing for SwiftPM's own build-graph check to
    /// find, and skipping it outright avoids paying for that check on every
    /// one of what can be hundreds of invocations, with no change to what
    /// coverage gets attributed to which test (confirmed: `swift test
    /// --skip-build --enable-code-coverage` still exports a fresh, correct,
    /// unaccumulated `codecov/*.json` per invocation). Each individual run's
    /// codecov JSON is read right after that run finishes and merged into a
    /// reverse index.
    ///
    /// A one-time cost paid once per execution, not per mutant: worth it on
    /// a real project, where the fixed cost of re-running an entire suite
    /// dominates every mutant's wall clock regardless of how few tests
    /// actually exercise the mutated line.
    ///
    /// The retry, and what becomes of a test that still cannot be proven,
    /// are `PerTestCoverageAttribution.attribute`'s — see its doc comment,
    /// and `PerTestCoverageMap`'s, for the policy and why it is safe. Two
    /// things specific to this adapter. The failure class includes a
    /// selection SwiftPM silently ran zero of (P12-B Finding A/B/C, before
    /// this adapter's own filter and `classify` fixes), which is why
    /// `reliableExpectedTestCount` is passed below. And a test that
    /// legitimately covers nothing — a genuine, successfully-read empty
    /// `CoverageMap` — is *not* that failure class here, unlike in
    /// `XcodeBuildAdapter`: it is fully attributed, contributing no lines.
    /// - Parameter artifact: `runBaseline`'s own, uninstrumented artifact —
    ///   unused here beyond satisfying the protocol; test identifiers come
    ///   from `swift test list`, not from the artifact, and per-test
    ///   coverage needs its own coverage-instrumented run regardless of what
    ///   `artifact` was built with.
    private func measurePerTestCoverageSerial(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        let enumerated = await Self.enumerateTestIdentifiers(
            in: resolvedWorkspace(workspace),
            timeoutSeconds: timeoutSeconds,
            terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
        )
        let tests = Self.scope(enumerated, toConfiguredTargets: configuration.tests.targets)
        guard !tests.isEmpty else { return nil }

        // Set only once a coverage-enabled run has completed *and* its
        // coverage was actually read -- not merely after an attempt
        // finished. A failed attempt (build error, infra failure, unreadable
        // coverage) must never leave a later iteration skipping the build
        // against an artifact that may not exist or may be stale, and that
        // matters in practice rather than only in principle: unlike the
        // all-or-nothing predecessor, the loop keeps going after a failure.
        var coverageArtifactBuilt = false

        // The loop, the retry policy and what becomes of a test that cannot
        // be proven are all `PerTestCoverageAttribution.attribute`'s -- see
        // its doc comment. What is adapter-specific, and all that is left
        // here, is how one test is run and how its coverage is read back.
        return await PerTestCoverageAttribution.attribute(
            tests: tests, source: "swiftpm-codecov-per-test",
            progress: ProgressReporter(total: tests.count, label: "per-test coverage")
        ) { test, _ in
            guard let run = try? await runTests(
                in: workspace,
                timeoutSeconds: timeoutSeconds,
                enableCoverage: true,
                skipBuild: coverageArtifactBuilt,
                testFilters: [test.swiftTestFilterArgument],
                reliableExpectedTestCount: test.isSwiftTestingShaped ? 1 : nil
            ) else { return nil }
            // `runTests`'s xunit report path is unique per invocation (never
            // reused by a later iteration), and this loop -- unlike a real
            // mutant run -- never preserves it as evidence afterward: once
            // this iteration is done with it, it is pure disk usage a
            // project with many discovered tests would otherwise accumulate
            // one report pair per test, for the lifetime of this whole
            // method's loop, inside one sandbox.
            Self.removeXUnitReports(at: run.resultArtifactPath)
            guard run.status == .passed else { return nil }

            guard let map = await readCoverage(in: workspace, projectRoot: workspace) else { return nil }
            coverageArtifactBuilt = true
            return map
        }
    }

    /// Removes the xunit report(s) one `measurePerTestCoverage` iteration's
    /// `runTests` call wrote, once this loop is done reading them. Best-
    /// effort: unlike the freshness fix this exists alongside, a failed
    /// removal here is not a correctness risk -- the path is unique per
    /// invocation and is never read again by anything, so a leftover file
    /// is at worst a little unclaimed disk space, not a stale report a
    /// later run could mistake for its own.
    private static func removeXUnitReports(at resultArtifactPath: URL?, fileManager: FileManager = .default) {
        guard let resultArtifactPath else { return }
        for candidate in XUnitParser.candidatePaths(for: resultArtifactPath) {
            try? fileManager.removeItem(at: candidate)
        }
    }

    /// Restricts `swift test list`'s package-wide enumeration to the
    /// configured target list — the same restriction every other `swift
    /// test` invocation in this file already applies (see `runTests`'s own
    /// `--filter` loop). Xcode's equivalent enumeration gets this scoping
    /// for free, because its baseline bundle was already produced by an
    /// `-only-testing:`-filtered run; SwiftPM's `swift test list` has no
    /// such target restriction of its own, so it is applied here instead.
    /// An empty `configuredTargets` means "no restriction configured", and
    /// every enumerated test is kept, matching every other unrestricted
    /// fallback in this file.
    static func scope(_ tests: [TestIdentifier], toConfiguredTargets configuredTargets: [String]) -> [TestIdentifier] {
        guard !configuredTargets.isEmpty else { return tests }
        let allowed = Set(configuredTargets)
        return tests.filter { allowed.contains($0.target) }
    }

    /// Parses `swift test list`'s stdout: one `<Target>.<Class>/<method>`
    /// per line (confirmed against a real invocation — SwiftPM writes build
    /// progress to stderr, so stdout is test identifiers alone, nothing to
    /// filter out). Exposed for tests so a captured sample can drive parsing
    /// without a toolchain.
    static func parseTestIdentifiers(_ output: String) -> [TestIdentifier] {
        output.split(separator: "\n").compactMap { rawLine -> TestIdentifier? in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let dotIndex = line.firstIndex(of: ".") else { return nil }
            let target = String(line[line.startIndex ..< dotIndex])
            let qualifiedName = String(line[line.index(after: dotIndex)...])
            guard !target.isEmpty, qualifiedName.contains("/") else { return nil }
            return TestIdentifier(target: target, qualifiedName: qualifiedName)
        }
    }

    /// Runs `swift test list --skip-build` and parses its output. `nil`/empty
    /// results (a launch failure, a non-zero exit, an unparseable line) all
    /// collapse to an empty list — `measurePerTestCoverage` already treats
    /// that as "no attribution possible", the same safe fallback every other
    /// failure path in this pass takes.
    static func enumerateTestIdentifiers(
        in workspace: URL,
        timeoutSeconds: Double,
        terminationGracePeriodSeconds: Double
    ) async -> [TestIdentifier] {
        let arguments = ["swift", "test", "list", "--skip-build"]
        guard let result = try? await ProcessSupervisor.run(
            executable: ToolPaths.xcrun,
            arguments: arguments,
            workingDirectory: workspace,
            timeoutSeconds: timeoutSeconds,
            terminationGracePeriodSeconds: terminationGracePeriodSeconds
        ), result.succeeded else { return [] }

        return parseTestIdentifiers(String(decoding: result.standardOutput, as: UTF8.self))
    }
}

private extension TestIdentifier {
    /// The exact string `swift test --filter` accepts for exactly this one
    /// test: an anchored regex over the same `<target>.<Class>/<method>`
    /// shape `swift test list` itself emits (see
    /// `SwiftPackageMacOSAdapter.parseTestIdentifiers`). `--filter` matches
    /// as a substring regex search, not an exact-match lookup, so both
    /// `target` and `qualifiedName` are escaped as regex *literals* — not
    /// just the `.` between them — and the whole thing is anchored with
    /// `^…`.
    ///
    /// `qualifiedName` is not just letters and slashes: a Swift Testing
    /// `@Test` function's own identifier includes its call parentheses
    /// (`seniorRateBoundary()`), which are regex metacharacters. Left
    /// unescaped, `()` at the end of a pattern is an empty capture group,
    /// not a literal match for the two characters `(` `)` — direct
    /// reproduction against a real Swift Testing target confirmed this
    /// alone is enough to make the previous, dot-only-escaped filter match
    /// **zero** tests, silently, exit code 0 included (P12-B Finding A/B).
    ///
    /// Swift Testing also filters at *runtime*, not in SwiftPM itself the
    /// way XCTest is, against `Test.ID.description` — which appends
    /// `/<file>:<line>:<column>` after the exact identifier `swift test
    /// list` reports, confirmed by direct reproduction against a throwaway
    /// probe package (`idprobeTests.idprobeTests/printsID()/…swift:6:6`).
    /// `list` itself never includes that suffix, so a bare `…$` anchor —
    /// correct for XCTest, which SwiftPM filters before that suffix ever
    /// enters the picture — cannot match a Swift Testing identifier's real
    /// runtime ID at all. `(?:/.*)?$` accepts that optional suffix without
    /// widening the match: `qualifiedName`'s own trailing `()` (or
    /// `(label:)` for a parameterised test) already means no *other*
    /// discovered identifier can share this literal prefix immediately
    /// followed by `/` or the end of the string, so this cannot pull in a
    /// second test the way a bare, unanchored prefix would.
    var swiftTestFilterArgument: String {
        let escapedTarget = NSRegularExpression.escapedPattern(for: target)
        let escapedQualifiedName = NSRegularExpression.escapedPattern(for: qualifiedName)
        return "^\(escapedTarget)\\.\(escapedQualifiedName)(?:/.*)?$"
    }

    /// Whether `swift test list` shaped this identifier the way it shapes
    /// every Swift Testing test: `qualifiedName` ending in the test
    /// function's own call parentheses (`Suite/method()`, or
    /// `Suite/method(label:)` for a parameterised one) — confirmed live in
    /// B0 reproduction against this package's own fixtures. An XCTest
    /// identifier's `qualifiedName` never does (`Class/method`, no trailing
    /// `()`). See `SwiftPackageMacOSAdapter.reliableExpectedCount(for:)` for
    /// why this specific, real distinction — not a guess — is what this
    /// adapter trusts before treating a narrowed selection's executed count
    /// as reliable evidence.
    var isSwiftTestingShaped: Bool { qualifiedName.hasSuffix(")") }
}

// MARK: - Project adapter

/// Pairs the host build and test halves.
public struct SwiftPackageMacOSProjectAdapter: ProjectAdapter {
    public let kind: ProjectKind = .swiftPackageMacOS
    public let build: any BuildAdapter
    public let test: any TestAdapter

    public init(configuration: Configuration) {
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)
        build = adapter
        test = adapter
    }
}
