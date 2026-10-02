import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend

/// Builds and tests anything that needs `xcodebuild`: `.xcodeproj`,
/// `.xcworkspace`, and Swift packages targeting a non-host Apple platform.
///
/// The package case is not an afterthought. A package declaring only iOS has no
/// host slice, so `swift test` cannot run it at all; routing it here is what lets
/// it link UIKit and run on a simulator.
public struct XcodeBuildAdapter: Sendable {
    let configuration: Configuration
    public let kind: ProjectKind
    /// The `.xcodeproj`/`.xcworkspace`, relative to the project root. `nil` for a
    /// package, where `xcodebuild` reads the manifest from the working directory.
    ///
    /// Stored relative rather than absolute so it can be re-resolved against each
    /// sandbox. Passing the original absolute path would build the user's real,
    /// unmutated sources while the mutated copy sat unread in the sandbox — every
    /// mutant would then produce a binary identical to the baseline's and the run
    /// would report a confident, meaningless score.
    let projectFileRelativePath: String?
    let resultReader: XCResultAdapter
    /// Shared across every mutant, which is the entire point: it is what stops two
    /// of them being handed the same device.
    let simulators: SimulatorPool
    /// The destination resolved once, at run start — see `DestinationResolver`.
    /// `nil` when no resolution has been performed (a caller that predates
    /// this, or an intentionally unresolved one-off invocation); every build
    /// and test call falls back to the previous, per-call resolution in that
    /// case, so this is purely additive.
    let resolvedDestination: ResolvedDestination?
    /// Per-worker device affinity: when set, `leaseAndRunTests` looks up the
    /// mutant's sandbox by `workspace.lastPathComponent` here *before*
    /// falling back to the single, run-wide `resolvedDestination.device`
    /// every worker otherwise shares. Keyed by
    /// `WorkspaceManager.directoryName(for:)`'s own hashed sandbox-name
    /// convention (computed once, by whoever provisions the pool — see
    /// `RunCommand`), not by the worker id string itself, since a sandbox's
    /// own directory name is the only worker-identifying value that
    /// actually reaches this adapter — no protocol change to
    /// `TestAdapter`/`BuildAdapter` was needed to thread a separate worker
    /// id down. `nil` (the default, and the only value every existing
    /// caller passes) reproduces today's single-shared-device behavior
    /// exactly.
    ///
    /// **Known limitation, documented rather than silently accepted:**
    /// crash/timeout *confirmation* runs (`MutationRunner`'s
    /// `-crash-confirm`/`-timeout-confirm` sandboxes) are created and named
    /// per-mutation-ID, never per-worker, so their
    /// `workspace.lastPathComponent` never matches a key in this
    /// dictionary — they always fall through to the
    /// `resolvedDestination?.device` branch below, i.e. the single shared
    /// base device, reintroducing exactly the contention `simulatorPool`
    /// exists to remove, but only for the confirmation re-run of a mutant
    /// already suspected to have crashed or hung, not for the primary,
    /// parallel test pass. A structural fix would need to know which
    /// worker's device produced the original crash/timeout so the
    /// confirmation run could reuse it — not knowable from this dictionary
    /// alone, since worker-to-mutant assignment is dynamic (`MutationQueue`
    /// hands mutants to whichever worker asks next, not a static mapping
    /// precomputed at provisioning time). Deferred rather than solved here:
    /// confirmation runs are rare (only suspected crashes/timeouts trigger
    /// one) relative to the primary pass this feature already parallelizes
    /// correctly.
    let workerDevicesByWorkspace: [String: SimulatorDevice]?
    /// How `uninstallStaleApp` actually spawns `simctl` —
    /// `AdapterSupport.swift`'s `ProcessRunner` seam. Every production path
    /// gets `defaultProcessRunner`; only the test-only initializer below
    /// substitutes anything else.
    ///
    /// Constructor-injected rather than passed per call because the callers
    /// that must be proven fail-closed (`runTestsAfterUninstall`,
    /// `runSchemataTokenAfterUninstall`) are already at this project's
    /// `function_parameter_count` ceiling, and because a scripted runner is
    /// the only way to pin the failure branches deterministically: a real
    /// `simctl` against a bogus UDID was assumed to fail the same way every
    /// time, and CI disproved that assumption.
    let processRunner: ProcessRunner

    /// Where each `xcodebuild -list -json` attempt's timing is appended, or
    /// `nil` to record nothing — the default on every path that does not say
    /// otherwise, since the variable is unset outside CI.
    ///
    /// Read once here rather than from the global environment at each call
    /// site so a test can point one adapter at its own file without setting a
    /// process-wide variable that every *other* adapter running concurrently
    /// in the same test process would then also write to.
    var schemeDiscoveryLogPath: String? =
        ProcessInfo.processInfo.environment[SchemeDiscoveryObservationLog.environmentVariable]

    public init(
        configuration: Configuration,
        kind: ProjectKind,
        projectFile: URL?,
        projectRoot: URL,
        resolvedDestination: ResolvedDestination? = nil,
        workerDevicesByWorkspace: [String: SimulatorDevice]? = nil
    ) {
        self.configuration = configuration
        self.kind = kind
        projectFileRelativePath = projectFile.flatMap { Self.relativePath(of: $0, under: projectRoot) }
        resultReader = XCResultAdapter()
        simulators = SimulatorPool(workingDirectory: projectRoot)
        self.resolvedDestination = resolvedDestination
        self.workerDevicesByWorkspace = workerDevicesByWorkspace
        processRunner = defaultProcessRunner
    }

    /// Test-only initializer that injects the simulator pool and the
    /// `simctl` process seam, so `prepareSimulatorForRun()`'s outcome
    /// mapping and `uninstallStaleApp`'s fail-closed contract can both be
    /// exercised against scripted doubles without a real simulator.
    /// Internal to keep it out of the public surface.
    init(
        configuration: Configuration,
        kind: ProjectKind,
        projectFile: URL?,
        projectRoot: URL,
        resolvedDestination: ResolvedDestination?,
        simulators: SimulatorPool,
        workerDevicesByWorkspace: [String: SimulatorDevice]? = nil,
        processRunner: @escaping ProcessRunner = defaultProcessRunner
    ) {
        self.configuration = configuration
        self.kind = kind
        projectFileRelativePath = projectFile.flatMap { Self.relativePath(of: $0, under: projectRoot) }
        resultReader = XCResultAdapter()
        self.simulators = simulators
        self.resolvedDestination = resolvedDestination
        self.workerDevicesByWorkspace = workerDevicesByWorkspace
        self.processRunner = processRunner
    }

    /// The device name in a destination string, if it names one.
    ///
    /// `platform=iOS Simulator,name=iPhone 17 Pro` → `iPhone 17 Pro`.
    static func deviceName(inDestination destination: String) -> String? {
        for field in destination.split(separator: ",") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "name" else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Whether this destination runs on a simulator device that must not be shared.
    ///
    /// A generic or macOS destination has no device to contend over. Unlike
    /// the original version of this check, a destination pinned to `id=` is
    /// *not* exempted: once `resolvedDestination` is set, `destination()`
    /// itself always returns an `id=` string (see below), and that device
    /// still needs exactly the same mutual exclusion an unresolved
    /// `name=` destination would have needed — the resolution changed
    /// *which* string names the device, not whether concurrent workers can
    /// still collide on it.
    var destinationNeedsSimulatorLease: Bool {
        let target = destination()
        // This used to check only `"iOS Simulator"`. A tvOS/watchOS/visionOS
        // destination is exactly as shared and exactly as unsafe for two
        // concurrent workers to install/run tests on at once as an iOS one
        // is — reusing `DestinationResolver.isSimulatorDestination` (the
        // same check that now also resolves those destinations to a pinned
        // device in the first place) rather than keeping a second, narrower
        // copy of this logic that would silently under-lease the three
        // platforms the other copy was just fixed for.
        return DestinationResolver.isSimulatorDestination(target)
            && !target.localizedCaseInsensitiveContains("generic/")
    }

    /// `nil` when the file lies outside the root — a layout we cannot sandbox, and
    /// one the caller must not silently paper over.
    static func relativePath(of file: URL, under root: URL) -> String? {
        let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    /// Boots and verifies readiness of the device this adapter's tests will
    /// run on, if it has a resolved simulator destination. No-op for macOS
    /// destinations, packages without a simulator, and adapters that were
    /// never given a `resolvedDestination`.
    ///
    /// Idempotent and cheap on a warm device: `bootstatus` returns
    /// immediately. The CLI calls this once at run start so the first
    /// `xcodebuild` test invocation does not pay the cold-boot tax or hit
    /// the CoreSimulator race a cold first install was found to hit.
    ///
    /// Returns a record of what happened — warm, cold, or failed — rather
    /// than dropping the result: the run logs it, persists it to the
    /// `RunManifest`, and (per the fail-closed policy in `RunCommand`) stops
    /// before the baseline if readiness could not be verified.
    public func prepareSimulatorForRun() async -> SimulatorPreparationRecord {
        guard let device = resolvedDestination?.device else {
            return SimulatorPreparationRecord(outcome: .notApplicable)
        }
        do {
            let outcome = try await simulators.prepare(udid: device.udid)
            return SimulatorPreparationRecord(
                outcome: outcome == .alreadyBooted ? .alreadyBooted : .prepared,
                udid: device.udid,
                name: device.name
            )
        } catch {
            return SimulatorPreparationRecord(
                outcome: .failed,
                udid: device.udid,
                name: device.name,
                detail: "\(error)"
            )
        }
    }

    // MARK: - Invocation shape

    /// `-workspace`/`-project` resolved inside `workspace`, or nothing for a package.
    private func projectArguments(in workspace: URL) -> [String] {
        guard let projectFileRelativePath else { return [] }
        let path = workspace.appendingPathComponent(projectFileRelativePath).path
        switch kind {
        case .xcodeWorkspace: return ["-workspace", path]
        case .xcodeProject: return ["-project", path]
        case .swiftPackageApple, .swiftPackageMacOS, .auto: return []
        }
    }

    /// Where DerivedData goes for this workspace.
    ///
    /// Always explicit, and meant to always stay inside the sandbox. Xcode's
    /// default is a shared path keyed by project name, so every concurrent
    /// mutant — each a copy of the same project, and therefore sharing that
    /// name — would build into one directory and overwrite the binaries the
    /// others are about to test. Mutants would then be scored against each
    /// other's products.
    ///
    /// The primary guarantee against that is upstream: `ConfigurationValidator`
    /// rejects an absolute `project.derivedDataPath` before a run ever starts,
    /// so this function should never actually be asked to resolve one. The
    /// `hasPrefix("/")` branch below is a defensive fallback, not the
    /// guarantee itself — kept because this adapter can be constructed
    /// directly (e.g. in tests) without going through that validation step.
    ///
    /// Same story for a symlinked path component that resolves outside the
    /// workspace (`derivedDataPath: ExternalDD/build` where `ExternalDD` is
    /// a symlink): `ConfigurationValidator` now rejects that too, by
    /// resolving symlinks against the real project directory and requiring
    /// a strict descendant. That check deliberately lives there, not here:
    /// this function only ever sees `workspace`, a per-worker sandbox
    /// already copied once the run has started, whereas the validator can
    /// inspect the original tree before any worker exists — the earliest
    /// point a symlink on disk can be observed at all. This function does
    /// not re-resolve and refuse on its own; doing so here would either
    /// silently coerce the path or crash a run a config-time check should
    /// already have stopped, and this codebase prefers the latter checked
    /// loudly up front (see the validator's doc comment).
    func derivedDataPath(in workspace: URL) -> URL {
        if let configured = configuration.project.derivedDataPath {
            // Checked on `configured` itself, not on `URL(fileURLWithPath:
            // configured).path` — that initializer always yields an absolute
            // path (resolving a relative input against the current working
            // directory), so testing the resolved URL's path would always be
            // true and this fallback would never actually resolve a relative
            // path against the workspace as intended.
            guard configured.hasPrefix("/") else {
                return workspace.appendingPathComponent(configured)
            }
            return URL(fileURLWithPath: configured)
        }
        return workspace.appendingPathComponent(".mutantkit/DerivedData", isDirectory: true)
    }

    /// `xcodebuild test-without-building` arguments, extracted so the target
    /// filter can be pinned without needing a real toolchain to run it against.
    ///
    /// An xctestrun built for a scheme with more than one test target (a UI test
    /// target alongside the unit tests, say) runs all of them unless told
    /// otherwise. Left unfiltered, `tests.targets` — which the SwiftPM adapter
    /// honours with `--filter` — would silently do nothing here, and every
    /// mutant's classification would include targets the user never asked to
    /// measure against: slower, and liable to fail the baseline on a UI test
    /// that has nothing to do with the mutation being scored.
    /// - Parameters:
    ///   - targets: what to run, as `-only-testing:` selectors. Accepts
    ///     either granularity the flag itself accepts: a bare test target
    ///     (`"AppTests"`, the normal case) or a single fully-qualified test
    ///     (`"AppTests/AddTests/testAdd"`, used to narrow a mutant's run to
    ///     the tests `TestSelecting` attributed to its line). Both are valid
    ///     `-only-testing:` selectors, so no separate code path is needed
    ///     for the narrowed case.
    ///   - enableCoverage: adds `-enableCodeCoverage YES`. Used for the
    ///     baseline run — whole-suite or, once per test, individually — that
    ///     `CoverageMeasuring`/`TestSelecting` read back afterward; never for
    ///     an ordinary mutant run, which has no use for the instrumentation
    ///     and would only pay its cost.
    static func testWithoutBuildingArguments(
        xctestrunPath: String,
        destination: String,
        resultBundlePath: String,
        targets: [String],
        extraArguments: [String],
        enableCoverage: Bool = false
    ) -> [String] {
        var arguments = [
            "test-without-building",
            "-xctestrun", xctestrunPath,
            "-destination", destination,
            // Always requested, so there is always a structured record to classify
            // from. Without it a failing run leaves only console text, and console
            // text is not something this tool is willing to decide an outcome from.
            "-resultBundlePath", resultBundlePath,
            // xcodebuild's default (`on-failure`) shells out to `simctl diagnose` —
            // a sysdiagnose-grade log collection with its own internal timeout in
            // the hundreds of seconds — the moment any mutant's first test fails,
            // which every survived-vs-killed mutant does by design half the time.
            // Found the hard way: a mutant can sit for minutes past what its own
            // test takes while this runs, racing mutantkit's own timeout — and if that
            // timeout fires first, the result bundle it kills mid-write is exactly
            // the shape a wrong verdict comes from. This tool builds its own
            // evidence from the structured result and the build product hash; it
            // has no use for a sysdiagnose.
            "-collect-test-diagnostics", "never"
        ]
        if enableCoverage {
            arguments.append(contentsOf: ["-enableCodeCoverage", "YES"])
        }
        for target in targets {
            arguments.append("-only-testing:\(target)")
        }
        arguments.append(contentsOf: extraArguments)
        return arguments
    }

    func productsDirectory(in workspace: URL) -> URL {
        derivedDataPath(in: workspace).appendingPathComponent("Build/Products", isDirectory: true)
    }

    /// The destination to build and test against.
    ///
    /// A package for a non-host platform needs a real one; guessing a specific
    /// simulator here would be the same class of mistake as guessing the
    /// `.xctestrun` name, so an unconfigured package asks for `generic/platform=iOS`
    /// at build time and requires a leased device at test time.
    ///
    /// `resolvedDestination` — when set — wins over the raw configuration:
    /// it is what `DestinationResolver` already resolved `name=`/implicit
    /// `OS:latest` to, once, at run start, and every build and test in the
    /// run must address that same device, not re-derive its own answer.
    func destination() -> String {
        if let resolvedDestination { return resolvedDestination.destinationArgument }
        if let configured = configuration.project.destination { return configured }
        return DestinationResolver.defaultDestination(for: kind)
    }

    // MARK: - Scheme

    /// The scheme to build.
    ///
    /// Resolved from configuration when given, otherwise discovered. Never
    /// derived from the project's name: SwiftPM's generated scheme is
    /// `<Package>-Package`, and an `.xcodeproj`'s schemes need not mention the
    /// project at all, so a name built by convention names something that does not
    /// exist.
    func resolveScheme(in workspace: URL) async throws -> String {
        if let configured = configuration.project.scheme { return configured }

        let discovery = await discoverSchemesWithDiagnostics(in: workspace)
        let schemes = discovery.schemes

        guard !schemes.isEmpty else {
            throw BuildFailure(
                kind: .infrastructure,
                diagnosis: SchemeResolutionDiagnosis.noSchemeResolved(
                    answered: discovery.answered,
                    lastResult: discovery.lastResult,
                    timeoutSeconds: Self.schemeListTimeoutSeconds
                ),
                command: listCommand(in: workspace, result: discovery.lastResult),
                output: discovery.lastResult?.combinedOutput ?? ""
            )
        }

        guard schemes.count == 1 else {
            throw BuildFailure(
                kind: .infrastructure,
                diagnosis: """
                \(schemes.count) schemes are available (\(schemes.joined(separator: ", "))) \
                and mutantkit will not choose for you. Set project.scheme in mutantkit.yml.
                """,
                command: listCommand(in: workspace, result: discovery.lastResult),
                output: discovery.lastResult?.combinedOutput ?? ""
            )
        }

        return schemes[0]
    }

    private func listCommand(in workspace: URL, result: ProcessResult?) -> CommandRecord {
        CommandRecording.record(
            executable: ToolPaths.xcodebuild,
            arguments: projectArguments(in: workspace) + ["-list", "-json"],
            workingDirectory: workspace,
            result: result
        )
    }

    /// Discovered schemes, or an empty list when discovery itself failed.
    ///
    /// Non-throwing because the two callers that take this plain `[String]`
    /// form (`XcodeConfigDetector`, `Diagnostics`) genuinely treat "could not
    /// ask" and "there are none" the same way: both mean no scheme can be
    /// resolved here and now, and neither caller is reporting a failure to a
    /// user. `resolveScheme` is the one that *is*, and it deliberately does
    /// not use this form — see `SchemeDiscoveryResult.answered`, and
    /// `SchemeResolutionDiagnosis` for the real CI failure that proved the
    /// two must not share one remedy.
    ///
    /// `public`, not just used internally by `resolveScheme`: `XcodeConfigDetector`
    /// (`init`/`doctor` auto-detection) needs this exact same real
    /// `xcodebuild -list -json` discovery, before any `Configuration` exists
    /// to construct a full adapter for a real run.
    ///
    /// Retries a *clean, fast, empty* result up to `emptyResultRetryCount`
    /// additional times before giving up — real CI evidence (2026-09-12,
    /// `xcode-project`'s own recurring "No schemes are available here"
    /// flake, reproduced identically 4 times) showed this exact call
    /// reporting zero schemes for a project whose shared scheme a
    /// *separate*, immediately preceding poll of the identical invocation
    /// had just confirmed visible — i.e. `xcodebuild`'s own scheme-visibility state can
    /// genuinely flicker under real resource pressure, not merely lag
    /// once and then stay caught up. This is a real robustness gap for
    /// any user on a loaded machine, not only a CI artifact, so the fix
    /// belongs here rather than in a test's own pre-flight wait. Only a
    /// clean empty result is retried, never a timeout or a crash — those
    /// already have their own, larger `timeoutSeconds` budget and retrying
    /// them here would only compound a real hang.
    public func discoverSchemes(in workspace: URL, emptyResultRetryCount: Int = 2) async -> [String] {
        await discoverSchemesWithDiagnostics(in: workspace, emptyResultRetryCount: emptyResultRetryCount).schemes
    }

    /// A discovery attempt's raw last `ProcessResult`, alongside the
    /// resolved scheme list — `resolveScheme`'s own thrown `BuildFailure`
    /// needs the real exit code/stdout/stderr for a genuine "no schemes"
    /// diagnosis (previously always `nil`, since `discoverSchemes`
    /// discarded the underlying `ProcessResult` entirely); `discoverSchemes`
    /// itself stays a plain `[String]` for its two other call sites
    /// (`XcodeConfigDetector`, `Diagnostics`), which have never needed more
    /// than the scheme list.
    struct SchemeDiscoveryResult {
        let schemes: [String]
        let lastResult: ProcessResult?
        /// Whether `xcodebuild` actually produced a scheme list to read.
        ///
        /// `schemes.isEmpty` alone cannot answer that, and conflating the
        /// two is precisely how a 120-second timeout with empty output got
        /// reported to a user as "no schemes are available here" — see
        /// `SchemeResolutionDiagnosis`. `false` means the emptiness is an
        /// absence of evidence; `true` means `xcodebuild` was asked, it
        /// answered, and the answer was none.
        let answered: Bool
    }

    /// `xcodebuild -list -json`'s own budget. Named rather than inlined so
    /// the diagnosis for a run killed at this deadline can quote the number
    /// the run was actually held to, instead of a second copy of it.
    static let schemeListTimeoutSeconds: Double = 120

    func discoverSchemesWithDiagnostics(
        in workspace: URL, emptyResultRetryCount: Int = 2
    ) async -> SchemeDiscoveryResult {
        let arguments = projectArguments(in: workspace) + ["-list", "-json"]
        // Every `return` below is preceded by one observation row, and the
        // fall-through case records one too, so the log holds one row per
        // attempt actually made -- successes included. Successes are the
        // whole point: three failures at the 120s deadline say the budget
        // touches the distribution's edge and nothing more, and the budget
        // stays where it is until the successful durations say what it
        // should be. See `SchemeDiscoveryObservationLog`.
        func observe(_ outcome: SchemeDiscoveryObservationLog.Outcome,
                     attempt: Int, result: ProcessResult?, schemeCount: Int) {
            SchemeDiscoveryObservationLog.record(
                attempt: attempt,
                outcome: outcome,
                result: result,
                schemeCount: schemeCount,
                budgetSeconds: Self.schemeListTimeoutSeconds,
                path: schemeDiscoveryLogPath
            )
        }
        for attempt in 0 ... emptyResultRetryCount {
            let result = try? await processRunner(
                ToolPaths.xcodebuild, arguments, workspace, Self.schemeListTimeoutSeconds
            )
            guard let result, result.succeeded else {
                observe(result == nil ? .notStarted : .didNotSucceed,
                        attempt: attempt, result: result, schemeCount: 0)
                return SchemeDiscoveryResult(schemes: [], lastResult: result, answered: false)
            }
            let schemes = SchemeListJSON.schemes(from: result.standardOutput)
            if !schemes.isEmpty {
                observe(.schemesFound, attempt: attempt, result: result, schemeCount: schemes.count)
                return SchemeDiscoveryResult(schemes: schemes, lastResult: result, answered: true)
            }
            // An empty list read out of output the supervisor never confirmed
            // it had fully drained is not an answer: `ProcessResult
            // .outputComplete`'s own contract requires every consumer that
            // derives a failure classification to fail closed here, and the
            // classification this feeds ("the project has no schemes") is
            // exactly the kind that must not rest on possibly-truncated
            // bytes. A *non-empty* list needs no such guard — truncated JSON
            // does not parse, so any scheme name read out at all came from
            // a complete document.
            guard result.outputComplete else {
                observe(.outputIncomplete, attempt: attempt, result: result, schemeCount: 0)
                return SchemeDiscoveryResult(schemes: [], lastResult: result, answered: false)
            }
            if attempt == emptyResultRetryCount {
                observe(.answeredNone, attempt: attempt, result: result, schemeCount: 0)
                return SchemeDiscoveryResult(schemes: [], lastResult: result, answered: true)
            }
            observe(.emptyRetrying, attempt: attempt, result: result, schemeCount: 0)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return SchemeDiscoveryResult(schemes: [], lastResult: nil, answered: false)
    }
}

// MARK: - Build

extension XcodeBuildAdapter: BuildAdapter {
    public func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        try await build(in: workspace)
    }

    public func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        try await build(in: workspace)
    }

    /// - Parameter enableCoverage: adds `-enableCodeCoverage YES` to
    ///   `build-for-testing` itself. Confirmed necessary, not just the test
    ///   invocation's own `-enableCodeCoverage YES`, on a real Xcode
    ///   project (a hand-authored `.xcodeproj`, not an auto-generated
    ///   SwiftPM scheme): source-based coverage is compiled in, and a
    ///   binary `build-for-testing` produced without the flag has no
    ///   instrumentation for `test-without-building` to retroactively turn
    ///   on — confirmed by a bundle whose `content-availability` reported
    ///   `hasCoverage: false` despite the test-time flag. Only ever used
    ///   for the dedicated coverage rebuild in `readCoverage`/
    ///   `measurePerTestCoverage`, never for `buildBaseline`/`buildMutant`:
    ///   an instrumented baseline's product hash would differ from every
    ///   mutant's uninstrumented one purely from the added profiling
    ///   counters, making every mutant look "activated" whether or not its
    ///   own edit actually reached the binary — the same reason
    ///   `SwiftPackageMacOSAdapter` captures its baseline's hash *before*
    ///   the coverage-instrumented test rebuild rather than after.
    private func build(in workspace: URL, enableCoverage: Bool = false, extraArguments: [String] = []) async throws -> BuildArtifact {
        let scheme = try await resolveScheme(in: workspace)
        let derivedData = derivedDataPath(in: workspace)

        // `build-for-testing`, not `build`: it produces the test bundles *and* the
        // `.xctestrun` that `test-without-building` needs, which is what lets the
        // build and test phases be timed and classified separately.
        var arguments = projectArguments(in: workspace) + [
            "build-for-testing",
            "-scheme", scheme,
            "-destination", destination(),
            "-derivedDataPath", derivedData.path
        ]
        // Build-setting overrides (e.g. XcodeLinkerInjector's OTHER_LDFLAGS/
        // LIBRARY_SEARCH_PATHS) go last, matching xcodebuild's own
        // convention of trailing NAME=value pairs after every flag.
        arguments.append(contentsOf: extraArguments)
        if enableCoverage {
            arguments.append(contentsOf: ["-enableCodeCoverage", "YES"])
        }

        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcodebuild,
                arguments: arguments,
                workingDirectory: workspace,
                timeoutSeconds: configuration.timeouts.baselineSeconds,
                terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
            )
        } catch {
            throw BuildFailure(
                kind: .infrastructure,
                diagnosis: "Could not launch xcodebuild: \(error)",
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild,
                    arguments: arguments,
                    workingDirectory: workspace,
                    result: nil
                ),
                output: ""
            )
        }

        let command = CommandRecording.record(
            executable: ToolPaths.xcodebuild,
            arguments: arguments,
            workingDirectory: workspace,
            result: result
        )

        guard result.succeeded else {
            throw BuildClassifier.failure(from: result, command: command)
        }

        let products = productsDirectory(in: workspace)
        let xctestrun = try XCTestRunLocator.locate(in: products, command: command)

        return BuildArtifact(
            productsDirectory: products,
            productHash: TestProductHasher.hash(productsDirectory: products),
            xctestrunPath: xctestrun,
            command: command
        )
    }

    public func diagnose() async throws -> BuildDiagnosis {
        await Diagnostics.full(adapter: self)
    }
}

// MARK: - Test

extension XcodeBuildAdapter: TestAdapter {
    public func runBaseline(
        _ artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async throws -> TestRunResult {
        try await runTests(
            artifact: artifact,
            in: workspace,
            label: "baseline",
            timeoutSeconds: timeoutSeconds,
            enableCoverage: configuration.execution.measureCoverage || configuration.execution.selectCoveringTests
        )
    }

    public func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async throws -> TestRunResult {
        try await runMutant(point, artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, selectedTests: nil)
    }

    /// Runs the tests, holding a simulator for exactly as long as they need it.
    ///
    /// Only the test phase leases. A build never boots the device, so builds still
    /// run fully in parallel — and they dominate the wall clock, so serializing on
    /// a scarce device costs much less than it appears to.
    ///
    /// Without this, concurrent mutants were handed the same `name=` destination
    /// and fought over one device. The loser did not fail cleanly: it exceeded its
    /// timeout, was recorded `timedOut`, and vanished from the score — which is
    /// excluded from both denominators. Two runs of the same plan then disagreed,
    /// intermittently and silently, on the tool's primary use case.
    private func runTests(
        artifact: BuildArtifact,
        in workspace: URL,
        label: String,
        timeoutSeconds: Double,
        testFilters: [String]? = nil,
        enableCoverage: Bool = false,
        expectedTestCount: Int? = nil
    ) async throws -> TestRunResult {
        guard destinationNeedsSimulatorLease else {
            return try await runTestsOnDestination(
                destination(), artifact: artifact, in: workspace, label: label, timeoutSeconds: timeoutSeconds,
                testFilters: testFilters, enableCoverage: enableCoverage, expectedTestCount: expectedTestCount
            )
        }

        do {
            return try await leaseAndRunTests(
                artifact: artifact, in: workspace, label: label, timeoutSeconds: timeoutSeconds,
                testFilters: testFilters, enableCoverage: enableCoverage, expectedTestCount: expectedTestCount
            )
        } catch let error as SimulatorPoolError {
            return TestRunResult(
                status: .infrastructureFailure,
                summary: nil,
                command: artifact.command,
                resultArtifactPath: nil,
                diagnosis: "No simulator could be leased for this mutant: \(error.description)"
            )
        }
    }

    /// Leases the device this run's tests must land on, runs them, and
    /// releases it — the shape shared by every path below, differing only in
    /// *which* device is unambiguous enough to lease directly.
    ///
    /// Three cases, most to least specific:
    /// - `resolvedDestination` names a concrete device (the normal path once
    ///   `DestinationResolver` has run): lease that exact UDID. No name to
    ///   re-derive, no runtime ambiguity possible.
    /// - No resolution happened, but the configured destination is already
    ///   pinned to `id=` (a caller set one explicitly, or an older code path
    ///   that predates resolution): lease that exact UDID too — `name=`
    ///   parsing would find nothing in an `id=`-only string and silently
    ///   fall back to leasing an arbitrary free device, which is not what an
    ///   explicit `id=` asked for.
    /// - Otherwise, the original name-hint behavior: narrowed to the device
    ///   the destination asked for, addressed by whichever UDID
    ///   `SimulatorPool` matches it to.
    ///
    /// Checked *before* any of the three cases above: the per-worker
    /// device (`workerDevicesByWorkspace`), when this mutant's persistent
    /// incremental-build sandbox (`workspace`) has one assigned. Still
    /// routed through `simulators.withLease(udid:)`, not used directly —
    /// exclusivity is structurally guaranteed here (each worker's own
    /// sandbox is only ever touched by that one worker, serially), but
    /// leasing anyway costs nothing and keeps "at most one lease per
    /// device" a real invariant the pool enforces, not one this call site
    /// merely assumes.
    /// The uninstall-then-launch decision itself, factored out of
    /// `leaseAndRunTests` so `XcodeBuildAdapterUninstallFailureTests` can
    /// drive it directly with a hand-built `SimulatorLease` — the same
    /// reason `uninstallStaleApp` itself is `internal`, not `private`: a
    /// real `SimulatorPool` lease needs a real, already-booted device, which
    /// a launch-suppression regression has no need to depend on. This is
    /// also the one place that actually enforces the fail-closed uninstall
    /// contract: a failed uninstall must never reach `runTestsOnDestination` at all.
    func runTestsAfterUninstall(
        lease: SimulatorLease,
        artifact: BuildArtifact,
        in workspace: URL,
        label: String,
        timeoutSeconds: Double,
        testFilters: [String]? = nil,
        enableCoverage: Bool = false,
        expectedTestCount: Int? = nil
    ) async throws -> TestRunResult {
        if case let .failed(bundleID, detail) = await uninstallStaleApp(artifact: artifact, from: lease) {
            return Self.uninstallFailureResult(bundleID: bundleID, udid: lease.device.udid, detail: detail, command: artifact.command)
        }
        return try await runTestsOnDestination(
            lease.destination, artifact: artifact, in: workspace, label: label, timeoutSeconds: timeoutSeconds,
            testFilters: testFilters, enableCoverage: enableCoverage, expectedTestCount: expectedTestCount
        )
    }

    private func leaseAndRunTests(
        artifact: BuildArtifact,
        in workspace: URL,
        label: String,
        timeoutSeconds: Double,
        testFilters: [String]? = nil,
        enableCoverage: Bool = false,
        expectedTestCount: Int? = nil
    ) async throws -> TestRunResult {
        func run(_ lease: SimulatorLease) async throws -> TestRunResult {
            try await runTestsAfterUninstall(
                lease: lease, artifact: artifact, in: workspace, label: label, timeoutSeconds: timeoutSeconds,
                testFilters: testFilters, enableCoverage: enableCoverage, expectedTestCount: expectedTestCount
            )
        }

        if let device = workerDevicesByWorkspace?[workspace.lastPathComponent] {
            return try await simulators.withLease(udid: device.udid, run)
        }
        if let device = resolvedDestination?.device {
            return try await simulators.withLease(udid: device.udid, run)
        }
        if let udid = Self.udid(inDestination: destination()) {
            return try await simulators.withLease(udid: udid, run)
        }
        let hint = Self.deviceName(inDestination: destination())
        return try await simulators.withLease(matching: hint, run)
    }

    /// The device UDID in a destination string, if it names one.
    ///
    /// `platform=iOS Simulator,id=8B23...` → `8B23...`.
    static func udid(inDestination destination: String) -> String? {
        for field in destination.split(separator: ",") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "id" else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Removes whatever this leased device already has installed under the
    /// mutant's own bundle identifier before it is tested.
    ///
    /// Confirmed necessary, not just suspected, on a real project (the Debug
    /// Dylib fixture): two mutants sharing one leased simulator device, run
    /// back to back by the pool exactly as designed, occasionally produced a
    /// verdict that matched neither binary — a mutation the build product
    /// proves reached the binary was reported `survived` although the
    /// identical, already-built sandbox failed deterministically when built
    /// and tested by hand outside the pool, on the same device, moments
    /// later. Disabling only this call (with the `-collect-test-diagnostics`
    /// fix below still active) reproduced the exact same impossible verdict
    /// on the very first run afterward; re-enabling it made three separate
    /// runs agree with ground truth. The pool guarantees no two mutants
    /// install at the same time; it says nothing about what CoreSimulator
    /// does with an app already registered under the same bundle identifier
    /// from the mutant before, and an explicit uninstall removes that
    /// variable outright rather than trusting `test-without-building` to
    /// notice the difference.
    ///
    /// **Fail-closed: a genuine `simctl uninstall` failure blocks
    /// this mutant's run** — the caller must never proceed to launch
    /// `xcodebuild test-without-building` once this returns `.failed`.
    /// Confirmed directly against a real simulator: `simctl uninstall` on a
    /// bundle ID that was never installed still **exits 0**, with no error
    /// output at all — "nothing to uninstall" is not distinguishable from
    /// "uninstalled successfully" at the exit-code level, and does not need
    /// to be, since both are the fully-expected, ordinary case this method
    /// exists to handle silently (`.ready`). That means a *non-zero* exit
    /// here is never the ordinary case — it is always a real failure (a busy
    /// device, a transient CoreSimulator fault, the same class of flake
    /// `SimulatorPool.prepare`'s own retry logic exists to absorb
    /// elsewhere).
    /// This method previously only logged a genuine failure (stderr) and let
    /// the caller proceed regardless — an earlier version of its own doc
    /// comment reasoned that surfacing the fact was enough. It was not: a
    /// stale install surviving an uninstall failure immediately before the
    /// next test run can make a runtime image UUID disagree with the build
    /// receipt, or a leftover process shadow a fresh mutant's own result,
    /// without needing a rebuild at all — exactly the class of
    /// infrastructure hazard this codebase otherwise never launches a real
    /// test run on top of (see the `boot`/`bootstatus` failure class,
    /// retried and diagnosed, never silently proceeded past). `report`
    /// still fires on every failure (mirroring `MutationRunner`'s own
    /// convention for an infrastructure hiccup that must not vanish
    /// silently from a human's view), but the return value is now what a
    /// caller must actually act on.
    /// return value is now what a caller must actually act on.
    ///
    /// `report` is a seam, not a production knob: every real caller uses the
    /// default (a real `FileHandle.standardError.write`), and
    /// `XcodeBuildAdapterUninstallFailureTests` overrides it to capture
    /// exactly what would have been reported, against a real `simctl`
    /// invocation with a deliberately-invalid device, without needing to
    /// intercept the process's actual stderr file descriptor. `internal`
    /// (not `private`), for the same reason: a test in another file needs
    /// to call this directly, bypassing the full `leaseAndRunTests` path
    /// that would otherwise require a real build and a real lease to reach
    /// it at all.
    /// The `simctl` invocation itself goes through this adapter's own
    /// `processRunner` property, so a scripted failure reaches every caller
    /// of this method — including `runTestsAfterUninstall` and
    /// `runSchemataTokenAfterUninstall`, whose launch-suppression contract
    /// can therefore be proven without a real simulator at all.
    enum StaleAppUninstallOutcome: Sendable, Equatable {
        case ready
        case failed(bundleID: String, detail: String)
    }

    func uninstallStaleApp(
        artifact: BuildArtifact, from lease: SimulatorLease,
        report: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) async -> StaleAppUninstallOutcome {
        guard let xctestrun = artifact.xctestrunPath else { return .ready }
        for bundleID in Self.bundleIdentifiers(inXCTestRun: xctestrun) {
            let result: ProcessResult?
            do {
                // `timeoutSeconds` was 30. Real public CI evidence
                // (2026-09-11) showed this `simctl uninstall` call
                // SIGTERM'd (exit 143) under real CI-load slowness —
                // `ProcessSupervisor.run`'s own timeout escalation firing
                // before `simctl` finished. Raised with real headroom
                // (30 -> 120), matching this session's other CI-load
                // timeout fixes (internal investigation notes, not part
                // of this public repo, have the full accumulated evidence).
                result = try await processRunner(
                    ToolPaths.xcrun,
                    ["simctl", "uninstall", lease.device.udid, bundleID],
                    FileManager.default.temporaryDirectory,
                    120
                )
            } catch {
                let detail = "\(error)"
                report(Self.uninstallFailureWarning(bundleID: bundleID, udid: lease.device.udid, detail: detail))
                return .failed(bundleID: bundleID, detail: detail)
            }
            if let result, !result.succeeded {
                let detail = Self.uninstallFailureDetail(result)
                report(Self.uninstallFailureWarning(bundleID: bundleID, udid: lease.device.udid, detail: detail))
                return .failed(bundleID: bundleID, detail: detail)
            }
        }
        return .ready
    }

    /// The `TestRunResult` a caller reports when `uninstallStaleApp` returns
    /// `.failed`, in place of ever launching `xcodebuild
    /// test-without-building` — the diagnosis text is the same
    /// `uninstallFailureWarning` a human watching the run sees on stderr, so
    /// a report reader sees exactly why this mutant never got a real test
    /// verdict.
    static func uninstallFailureResult(bundleID: String, udid: String, detail: String, command: CommandRecord) -> TestRunResult {
        TestRunResult(
            status: .infrastructureFailure, summary: nil, command: command, resultArtifactPath: nil,
            diagnosis: uninstallFailureWarning(bundleID: bundleID, udid: udid, detail: detail).trimmingCharacters(in: .newlines)
        )
    }

    /// The `.failed` detail for a non-zero `simctl uninstall`, in the three
    /// shapes a real failure can arrive in — none of which may produce an
    /// empty string. A fail-closed outcome whose diagnosis says nothing is
    /// indistinguishable, to whoever later reads the report, from a check
    /// that never ran; "zero work" must not be able to look like an answer.
    ///
    /// - Capture incomplete (`ProcessResult.outputComplete == false`): say
    ///   so explicitly rather than pass a partial read off as the whole
    ///   story. See `ProcessResult.outputComplete`'s own doc comment.
    /// - Captured in full, with content: that content, redacted and
    ///   truncated. This is the ordinary case (`Invalid device: ...`).
    /// - Captured in full and genuinely empty: name the exit code, because
    ///   "simctl failed and wrote nothing" is itself the diagnosis. Before
    ///   this branch existed the detail was the empty string, and the
    ///   warning a human saw ended in a bare colon.
    ///
    /// A pure function over an already-observed `ProcessResult`, so the
    /// contract tests pin all three branches deterministically without a
    /// real `simctl` invocation.
    static func uninstallFailureDetail(_ result: ProcessResult) -> String {
        guard result.outputComplete else {
            return "subprocess output incomplete (stdout/stderr could not be fully captured before the process exited)"
        }
        let captured = OutputRedactor.redactAndTruncate(result.combinedOutput, limit: 400)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard captured.isEmpty else { return captured }
        return "simctl exited \(result.exitCode) without writing any diagnostic output"
    }

    /// The exact text `uninstallStaleApp` reports for a genuine failure —
    /// a pure function so `XcodeBuildAdapterUninstallFailureTests` can pin
    /// its wording directly, independent of whichever real `simctl` error
    /// text happened to be observed.
    static func uninstallFailureWarning(bundleID: String, udid: String, detail: String) -> String {
        "warning: could not uninstall stale app \(bundleID) from simulator \(udid) before this mutant's test run: \(detail)\n"
    }

    /// Every `TestHostBundleIdentifier` named in a `.xctestrun` plist — the app
    /// each test target is hosted inside, and so the app a stale simulator
    /// install of it could shadow. Same two on-disk shapes as
    /// `Diagnostics.testTargets(inXCTestRun:)`: format version 2 nests targets
    /// under `TestConfigurations`, version 1 puts them at the top level next to
    /// a metadata key.
    static func bundleIdentifiers(inXCTestRun url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any]
        else { return [] }

        let targets: [[String: Any]] = if let configurations = root["TestConfigurations"] as? [[String: Any]] {
            configurations.flatMap { $0["TestTargets"] as? [[String: Any]] ?? [] }
        } else {
            root.values.compactMap { $0 as? [String: Any] }
        }

        return Array(Set(targets.compactMap { $0["TestHostBundleIdentifier"] as? String })).sorted()
    }

    private func runTestsOnDestination(
        _ destination: String,
        artifact: BuildArtifact,
        in workspace: URL,
        label: String,
        timeoutSeconds: Double,
        testFilters: [String]? = nil,
        enableCoverage: Bool = false,
        expectedTestCount: Int? = nil
    ) async throws -> TestRunResult {
        guard let xctestrun = artifact.xctestrunPath else {
            return TestRunResult(
                status: .infrastructureFailure,
                summary: nil,
                command: artifact.command,
                resultArtifactPath: nil,
                diagnosis: """
                The build produced no .xctestrun, so there is nothing for \
                test-without-building to run.
                """
            )
        }

        let resultBundle = resultBundlePath(in: workspace, label: label)
        // xcodebuild refuses to overwrite an existing bundle, and a retry must not
        // fail for that reason alone.
        try? FileManager.default.removeItem(at: resultBundle)
        try? FileManager.default.createDirectory(
            at: resultBundle.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let arguments = Self.testWithoutBuildingArguments(
            xctestrunPath: xctestrun.path,
            destination: destination,
            resultBundlePath: resultBundle.path,
            targets: testFilters ?? configuration.tests.targets,
            extraArguments: configuration.tests.extraArguments,
            enableCoverage: enableCoverage
        )

        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcodebuild,
                arguments: arguments,
                workingDirectory: workspace,
                timeoutSeconds: timeoutSeconds,
                terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
            )
        } catch {
            return TestRunResult(
                status: .infrastructureFailure,
                summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild,
                    arguments: arguments,
                    workingDirectory: workspace,
                    result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "Could not launch xcodebuild: \(error)"
            )
        }

        let command = CommandRecording.record(
            executable: ToolPaths.xcodebuild,
            arguments: arguments,
            workingDirectory: workspace,
            result: result
        )

        // The timeout is the one outcome the bundle cannot describe: a killed run
        // leaves a partial bundle, or none. The supervisor's verdict is the fact.
        if result.timedOut {
            return TestRunResult(
                status: .timedOut,
                summary: nil,
                command: command,
                resultArtifactPath: FileManager.default.fileExists(atPath: resultBundle.path)
                    ? resultBundle : nil,
                diagnosis: """
                The test run exceeded its \(String(format: "%.0f", timeoutSeconds))s limit \
                and was terminated.
                """
            )
        }

        // Everything else comes from the bundle, including success. xcodebuild's
        // exit code is deliberately not consulted: it reports 65 both for a failing
        // test and for a runner that never started, and only the bundle can tell
        // those apart.
        let outcome = await resultReader.classify(
            resultBundle: resultBundle, workingDirectory: workspace, expectedTestCount: expectedTestCount
        )

        return TestRunResult(
            status: outcome.status,
            summary: outcome.summary,
            command: command,
            resultArtifactPath: FileManager.default.fileExists(atPath: resultBundle.path)
                ? resultBundle : nil,
            diagnosis: outcome.diagnosis
        )
    }

    /// A bundle path unique to this run.
    ///
    /// Keyed by mutation ID because concurrent workers share a machine, and a
    /// second `test-without-building` writing to a path a first is still reading
    /// would corrupt both records.
    private func resultBundlePath(in workspace: URL, label: String) -> URL {
        let safe = label.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return workspace
            .appendingPathComponent(".mutantkit/Results", isDirectory: true)
            .appendingPathComponent("\(String(safe)).xcresult")
    }
}

// MARK: - Schemata build

extension XcodeBuildAdapter: SchemataBuildable {
    public func buildSchemataChunk(loweredSources: [SchemataSourceFile], in workspace: URL) async throws -> BuildArtifact {
        for source in loweredSources {
            try SchemataSourceWriter.write(source, in: workspace)
        }

        let target = destination()
        guard let platform = SchemataRuntimePlatform.resolve(destination: target) else {
            throw SchemataRuntimeLibraryLocator.LocatorError.unsupportedDestination(target)
        }
        let located = try SchemataRuntimeLibraryLocator.locate(for: platform)
        let linkerArguments = XcodeLinkerInjector.extraArguments(archivePath: located.archivePath)
        let buildStart = GateTimingRecorder.shared.now()
        let artifact = try await build(in: workspace, extraArguments: linkerArguments)
        await GateTimingRecorder.shared.record("chunk.build", chunkID: workspace.lastPathComponent, start: buildStart)
        return artifact
    }

    public func resolveSchemataBuildReceipt(
        for units: [SchemataCompilationUnitTargetRequest],
        artifact: BuildArtifact,
        in workspace: URL,
        context: SchemataBuildReceiptContext
    ) async throws -> SchemataBuildReceipt {
        let receiptStart = GateTimingRecorder.shared.now()
        defer {
            Task { await GateTimingRecorder.shared.record("receipt.resolve", chunkID: context.chunkID, start: receiptStart) }
        }
        // Deliberately not `destination()`: reading back where this chunk's
        // product was written must not depend on the run's device still
        // existing — see `DestinationResolver.buildSettingsDestination(for:)`.
        let buildSettingsContext = XcodeCompilationUnitImageResolver.BuildSettingsContext(
            projectArguments: projectArguments(in: workspace), scheme: try await resolveScheme(in: workspace),
            destination: DestinationResolver.buildSettingsDestination(for: destination()),
            derivedDataPath: derivedDataPath(in: workspace), workspace: workspace, timeoutSeconds: configuration.timeouts.baselineSeconds
        )
        let targetsByName = Dictionary(grouping: units, by: \.buildTarget.targetName)

        var imagesByTarget: [BuildTargetIdentity: BuiltImageReceipt] = [:]
        for (targetName, requests) in targetsByName {
            let buildTarget = requests[0].buildTarget
            let resolved = try await XcodeCompilationUnitImageResolver.resolveArtifactPath(
                target: targetName, context: buildSettingsContext
            )
            let discovered = try SchemataBuiltImageInspection.inspectSingle(at: resolved.path, bundleName: resolved.bundleName)
            imagesByTarget[buildTarget] = try BuiltImageReceipt(
                buildTarget: buildTarget, binaryPath: discovered.binaryPath, contentHash: discovered.contentHash, slices: discovered.slices
            )
        }

        let compilationUnits = units.map {
            CompilationUnitReceipt(
                compilationUnitID: $0.compilationUnitID, sourceEmbeddingID: $0.sourceEmbeddingID, buildTarget: $0.buildTarget
            )
        }

        return try SchemataBuildReceipt(
            planID: context.planID, workUnitID: context.workUnitID, chunkID: context.chunkID,
            toolchainHash: context.toolchainHash, buildArgumentsHash: context.buildArgumentsHash,
            runtimeABIVersion: UInt32(BoolLiteralSchemataLowerer.runtimeABIVersion),
            images: Array(imagesByTarget.values), compilationUnits: compilationUnits
        )
    }
}

// MARK: - Schemata test

extension XcodeBuildAdapter: SchemataTestable {
    /// Runs the already-built schemata chunk once for one requested token,
    /// without rebuilding — the Xcode analogue of `SwiftPackageMacOSAdapter
    /// .runSchemataToken`. Simulator leasing mirrors `runTests`/
    /// `leaseAndRunTests` exactly (only the test phase leases a device; a
    /// build never does).
    public func runSchemataToken(
        _ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double, environment: [String: String],
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        // Same empty-means-nil normalisation `TestSelecting.runMutant` uses
        // above: an empty selection is never sent to `-only-testing:`, which
        // would run nothing. Falls back to the full configured list, same as
        // `selectedTests == nil`.
        let filters = selectedTests.flatMap { $0.isEmpty ? nil : $0.map(\.onlyTestingArgument) }
        guard destinationNeedsSimulatorLease else {
            return try await runSchemataTokenOnDestination(
                destination(), artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, environment: environment,
                testFilters: filters
            )
        }

        do {
            return try await leaseAndRunSchemataToken(
                artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, environment: environment, testFilters: filters
            )
        } catch let error as SimulatorPoolError {
            return TestRunResult(
                status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                diagnosis: "No simulator could be leased for this schemata token run: \(error.description)"
            )
        }
    }

    /// The schemata-path counterpart to `runTestsAfterUninstall` — same
    /// reason it exists as a directly-testable, `internal` seam: proving
    /// the fail-closed uninstall contract holds for the schemata launch path too, without
    /// needing a real `SimulatorPool` lease to reach it.
    func runSchemataTokenAfterUninstall(
        lease: SimulatorLease, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double,
        environment: [String: String], testFilters: [String]?
    ) async throws -> TestRunResult {
        let uninstallStart = GateTimingRecorder.shared.now()
        let uninstallOutcome = await uninstallStaleApp(artifact: artifact, from: lease)
        await GateTimingRecorder.shared.record("token.uninstall", start: uninstallStart)
        if case let .failed(bundleID, detail) = uninstallOutcome {
            return Self.uninstallFailureResult(bundleID: bundleID, udid: lease.device.udid, detail: detail, command: artifact.command)
        }
        return try await runSchemataTokenOnDestination(
            lease.destination, artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, environment: environment,
            testFilters: testFilters
        )
    }

    private func leaseAndRunSchemataToken(
        artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double, environment: [String: String], testFilters: [String]?
    ) async throws -> TestRunResult {
        func run(_ lease: SimulatorLease) async throws -> TestRunResult {
            try await runSchemataTokenAfterUninstall(
                lease: lease, artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds,
                environment: environment, testFilters: testFilters
            )
        }

        let leaseAndRunStart = GateTimingRecorder.shared.now()
        defer {
            Task { await GateTimingRecorder.shared.record("token.leaseAndRun.total", start: leaseAndRunStart) }
        }
        if let device = resolvedDestination?.device {
            return try await simulators.withLease(udid: device.udid, run)
        }
        if let udid = Self.udid(inDestination: destination()) {
            return try await simulators.withLease(udid: udid, run)
        }
        let hint = Self.deviceName(inDestination: destination())
        return try await simulators.withLease(matching: hint, run)
    }

    /// `SchemataXcodeRuntimeAcceptanceTests` already proved by hand: setting
    /// `Process.environment` on the `xcodebuild test-without-building`
    /// invocation itself does not reliably reach the actual `xctest`
    /// process Xcode's own tooling launches — env vars must be injected
    /// into the `.xctestrun` plist's `EnvironmentVariables` dictionary
    /// instead, the same mechanism a scheme's own "Environment Variables"
    /// editor pane ultimately writes to. This writes a fresh variant of
    /// `artifact`'s own `.xctestrun` with `environment` merged in, per
    /// mutant, rather than mutating the one shared file every mutant's
    /// build produced (which concurrent mutants running against the same
    /// chunk build would otherwise race on).
    private func runSchemataTokenOnDestination(
        _ destination: String, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double, environment: [String: String],
        testFilters: [String]? = nil
    ) async throws -> TestRunResult {
        guard let baseXCTestRun = artifact.xctestrunPath else {
            return TestRunResult(
                status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                diagnosis: "The build produced no .xctestrun, so there is nothing for test-without-building to run."
            )
        }

        let variantXCTestRun: URL
        let variantStart = GateTimingRecorder.shared.now()
        do {
            variantXCTestRun = try Self.xctestrunVariant(mergingEnvironment: environment, into: baseXCTestRun)
        } catch {
            return TestRunResult(
                status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                diagnosis: "Could not write a schemata .xctestrun variant: \(error)"
            )
        }
        await GateTimingRecorder.shared.record("token.xctestrunVariant", start: variantStart)

        let resultBundle = resultBundlePath(in: workspace, label: "schemata-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: resultBundle)
        try? FileManager.default.createDirectory(
            at: resultBundle.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let arguments = Self.testWithoutBuildingArguments(
            xctestrunPath: variantXCTestRun.path, destination: destination, resultBundlePath: resultBundle.path,
            targets: testFilters ?? configuration.tests.targets, extraArguments: configuration.tests.extraArguments
        )

        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcodebuild, arguments: arguments, workingDirectory: workspace,
                timeoutSeconds: timeoutSeconds, terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
            )
        } catch {
            return TestRunResult(
                status: .infrastructureFailure,
                summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild, arguments: arguments, workingDirectory: workspace, result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "Could not launch xcodebuild: \(error)"
            )
        }

        let command = CommandRecording.record(
            executable: ToolPaths.xcodebuild, arguments: arguments, workingDirectory: workspace, result: result
        )

        if result.timedOut {
            return TestRunResult(
                status: .timedOut, summary: nil, command: command,
                resultArtifactPath: FileManager.default.fileExists(atPath: resultBundle.path) ? resultBundle : nil,
                diagnosis: """
                The schemata test run exceeded its \(String(format: "%.0f", timeoutSeconds))s limit \
                and was terminated.
                """
            )
        }

        let classifyStart = GateTimingRecorder.shared.now()
        let outcome = await resultReader.classify(resultBundle: resultBundle, workingDirectory: workspace)
        await GateTimingRecorder.shared.record("token.xcresultClassify", start: classifyStart)
        return TestRunResult(
            status: outcome.status, summary: outcome.summary, command: command,
            resultArtifactPath: FileManager.default.fileExists(atPath: resultBundle.path) ? resultBundle : nil,
            diagnosis: outcome.diagnosis
        )
    }

    private enum XCTestRunVariantError: Error, CustomStringConvertible {
        case malformed(String)
        case writeFailed(String)

        var description: String {
            switch self {
            case let .malformed(path): "malformed .xctestrun at \(path)"
            case let .writeFailed(path): "could not write .xctestrun variant at \(path)"
            }
        }
    }

    /// Writes the variant *next to* `base`, in the same directory — not
    /// under some other convenience location like `.mutantkit/`. An
    /// `.xctestrun`'s own paths are resolved relative to `__TESTROOT__`,
    /// which Xcode derives from wherever the `.xctestrun` file itself
    /// physically sits, not from any field recorded inside it. Confirmed
    /// the hard way: a variant written to a different directory than the
    /// original resolved its test bundle path relative to *that*
    /// directory instead, and `test-without-building` failed with
    /// "Missing test product" for a bundle that, moments earlier, the
    /// original (unmoved) `.xctestrun` found without trouble.
    private static func xctestrunVariant(mergingEnvironment environment: [String: String], into base: URL) throws -> URL {
        guard var plist = NSDictionary(contentsOf: base) as? [String: Any] else {
            throw XCTestRunVariantError.malformed(base.path)
        }

        // Same two on-disk shapes `bundleIdentifiers(inXCTestRun:)` above
        // already handles: format version 2 nests each real test target
        // under `TestConfigurations[].TestTargets[]`; version 1 puts every
        // target directly at the top level next to `__xctestrun_metadata__`.
        // Only handling the flat v1 shape here silently drops every
        // injected environment variable on a version-2 `.xctestrun` (the
        // shape Xcode 26 generates): `TestConfigurations`'s value is an
        // array, so `as? [String: Any]` fails and the whole key is skipped,
        // while the two top-level keys that *do* happen to be dictionaries
        // (`ContainerInfo`, `TestPlan`) are not test targets at all and
        // silently absorb the write instead.
        if var configurations = plist["TestConfigurations"] as? [[String: Any]] {
            for configIndex in configurations.indices {
                guard var targets = configurations[configIndex]["TestTargets"] as? [[String: Any]] else { continue }
                for targetIndex in targets.indices {
                    var targetEnvironment = targets[targetIndex]["EnvironmentVariables"] as? [String: String] ?? [:]
                    for (variable, value) in environment { targetEnvironment[variable] = value }
                    targets[targetIndex]["EnvironmentVariables"] = targetEnvironment
                }
                configurations[configIndex]["TestTargets"] = targets
            }
            plist["TestConfigurations"] = configurations
        } else {
            for key in plist.keys where key != "__xctestrun_metadata__" {
                guard var target = plist[key] as? [String: Any] else { continue }
                var targetEnvironment = target["EnvironmentVariables"] as? [String: String] ?? [:]
                for (variable, value) in environment { targetEnvironment[variable] = value }
                target["EnvironmentVariables"] = targetEnvironment
                plist[key] = target
            }
        }

        let variant = base.deletingLastPathComponent().appendingPathComponent("variant-\(UUID().uuidString).xctestrun")
        // `NSDictionary.write(to:atomically:)` is the non-throwing
        // Objective-C-era API — `try` on it compiles but silently
        // discards a `false` (failure) return, exactly the kind of quiet
        // failure this whole proof chain exists to refuse. The `Bool`
        // result is checked explicitly instead.
        guard (plist as NSDictionary).write(to: variant, atomically: true) else {
            throw XCTestRunVariantError.writeFailed(variant.path)
        }
        return variant
    }
}

// MARK: - Coverage

extension XcodeBuildAdapter: CoverageMeasuring {
    /// Rebuilds and re-tests the baseline once more, this time with
    /// coverage instrumentation, and reads back the result. Deliberately a
    /// second build rather than reusing `runBaseline`'s own bundle: that
    /// build was never instrumented (see `build(in:enableCoverage:)`), so
    /// its bundle has no coverage to read regardless of what flag the test
    /// step is given. `nil` when the rebuild, the retest, or the read
    /// itself fails — coverage is opt-in evidence; its absence never
    /// becomes a fabricated claim.
    public func readCoverage(in workspace: URL, projectRoot: URL) async -> CoverageMap? {
        guard let artifact = try? await build(in: workspace, enableCoverage: true) else { return nil }
        guard let run = try? await runTests(
            artifact: artifact,
            in: workspace,
            label: "coverage-baseline",
            timeoutSeconds: configuration.timeouts.baselineSeconds,
            enableCoverage: true
        ), run.status == .passed, let bundle = run.resultArtifactPath else { return nil }

        return await XccovCoverageReader.read(archive: bundle, projectRoot: projectRoot)
    }
}

// MARK: - Test selection

extension XcodeBuildAdapter: TestSelecting {
    public func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        // An empty selection is never sent to `-only-testing:` — that would
        // run nothing, and a run that tested nothing must never be mistaken
        // for one that passed. Falls back to the full configured list, the
        // same as `selectedTests == nil`.
        let filters = selectedTests.flatMap { $0.isEmpty ? nil : $0.map(\.onlyTestingArgument) }
        return try await runTests(
            artifact: artifact,
            in: workspace,
            label: point.id.description,
            timeoutSeconds: timeoutSeconds,
            testFilters: filters,
            // Only meaningful when the selection is truly narrowed: each
            // identifier in `selectedTests` names exactly one test, so its
            // count is the exact number of tests this run is expected to
            // execute. `configuration.tests.targets`, `filters`' own
            // fallback whenever `selectedTests` is nil/empty, names targets
            // (whole suites) instead — its count is not a test count at
            // all, so this must stay nil in that case rather than pass a
            // number that would misfire the zero-work invariant below.
            expectedTestCount: filters?.count
        )
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

    /// Runs every test the baseline bundle reports, one at a time, against
    /// the artifact already built for the baseline — no rebuild — with
    /// coverage enabled and its own scratch result bundle, and merges what
    /// each one touched into a reverse index.
    ///
    /// A one-time cost paid once per execution, not per mutant: found worth
    /// it on a real project, where the fixed cost of re-running an entire
    /// suite dominated every mutant's wall clock regardless of how few tests
    /// actually exercised the mutated line. Runs sequentially, one simulator
    /// lease at a time via `runTests`; spreading this pass across several
    /// leased devices concurrently is a further optimisation, not attempted
    /// here.
    ///
    /// The retry, and what becomes of a test that still cannot be proven,
    /// are `PerTestCoverageAttribution.attribute`'s — see its doc comment,
    /// and `PerTestCoverageMap`'s, for the policy and why it is safe. One
    /// thing specific to this adapter: a test that legitimately covers
    /// nothing is not distinguished from one that could not be measured,
    /// because `XccovCoverageReader.read` conservatively folds a
    /// validly-parsed, genuinely-empty export into the same `nil` a
    /// malformed one produces (see its own doc comment). Such a test is
    /// therefore treated as unattributed — safe, since that only means it is
    /// always run, but not the narrowest correct behaviour; sharpening it is
    /// a performance question for later.
    /// - Parameter artifact: `runBaseline`'s own, uninstrumented artifact —
    ///   kept only to enumerate test identifiers from its already-produced
    ///   bundle; never built or tested against directly. Per-test coverage
    ///   needs a coverage-instrumented binary (see
    ///   `build(in:enableCoverage:)`), built once here and reused for
    ///   every individual test run, exactly the same "instrumented copy is
    ///   never what activation evidence is measured against" split
    ///   `readCoverage` makes.
    private func measurePerTestCoverageSerial(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        let baselineBundle = resultBundlePath(in: workspace, label: "baseline")
        let tests = await Self.enumerateTestIdentifiers(inBundle: baselineBundle)
        guard !tests.isEmpty else { return nil }

        guard let coverageArtifact = try? await build(in: workspace, enableCoverage: true) else { return nil }

        // The loop, the retry policy and what becomes of a test that cannot
        // be proven are all `PerTestCoverageAttribution.attribute`'s — see
        // its doc comment. What is adapter-specific, and all that is left
        // here, is how one test is run and how its coverage is read back.
        return await PerTestCoverageAttribution.attribute(
            tests: tests, source: "xcodebuild-xccov-per-test",
            progress: MutationProgressReporter(total: tests.count, label: "per-test coverage")
        ) { test, attempt in
            guard let run = try? await runTests(
                artifact: coverageArtifact,
                in: workspace,
                // Distinct per attempt: a retry that reused the first
                // attempt's bundle path would be read against whatever the
                // failed attempt left behind, which is precisely the
                // half-written state being retried past.
                label: attempt == 1
                    ? "pertest-\(test.onlyTestingArgument)"
                    : "pertest-retry\(attempt)-\(test.onlyTestingArgument)",
                timeoutSeconds: timeoutSeconds,
                testFilters: [test.onlyTestingArgument],
                enableCoverage: true
            ) else { return nil }
            guard run.status == .passed, let bundle = run.resultArtifactPath else { return nil }
            return await XccovCoverageReader.read(archive: bundle, projectRoot: workspace)
        }
    }

    /// Walks `xcresulttool get test-results tests` for one bundle, pulling
    /// out every `Test Case` leaf and the `Unit test bundle` ancestor that
    /// names its target — the two things `-only-testing:` needs. A `Test
    /// Case` node's own `nodeIdentifier` is already shaped `Class/method()`
    /// (confirmed against a real bundle), so no separate class-name
    /// tracking is needed; only the trailing `()` is stripped.
    static func enumerateTestIdentifiers(inBundle bundle: URL) async -> [TestIdentifier] {
        guard FileManager.default.fileExists(atPath: bundle.path) else { return [] }

        let result = try? await ProcessSupervisor.run(
            executable: ToolPaths.xcrun,
            arguments: ["xcresulttool", "get", "test-results", "tests", "--path", bundle.path, "--compact"],
            workingDirectory: bundle.deletingLastPathComponent(),
            timeoutSeconds: 120
        )
        guard let result, result.succeeded else { return [] }
        return parseTestIdentifiers(result.standardOutput)
    }

    /// Parses `xcresulttool get test-results tests --compact` output. Exposed
    /// for tests so a captured document can drive the walk without a
    /// toolchain or a real bundle.
    ///
    /// `qualifiedName`'s own doc comment describes `"<Class>/<method>"` —
    /// true for XCTest, whose `nodeIdentifier` is exactly that shape
    /// (`"AddTests/testAdd()"`, confirmed by `XcodeTestIdentifierEnumerationTests`'
    /// own captured fixture). A Swift Testing `nodeIdentifier` is shaped
    /// differently — confirmed by direct reproduction against a real
    /// Xcode/iOS-Simulator Swift Testing target: it is
    /// `"<Target>/<method>()"` (the *target* name, never the enclosing
    /// `@Suite`'s own name, which never appears in the identifier at all)
    /// — so `qualifiedName` for a Swift Testing test ends up
    /// `"<Target>/<method>"`, not `"<Class>/<method>"`. This looks
    /// unusual next to the XCTest case, but it is exactly what makes
    /// `onlyTestingArgument` (`target + "/" + qualifiedName + "()"`)
    /// produce the one filter shape `xcodebuild -only-testing:` actually
    /// matches for a Swift Testing function — empirically, that shape is
    /// `<Target>/<Target>/<method>()` (the target name doubled), not
    /// `<Target>/<SuiteName>/<method>()` as the XCTest-shaped convention
    /// would suggest. See `TestIdentifier.onlyTestingArgument`'s own doc
    /// comment for the full account, including why this was previously
    /// silently broken (missing `()`, not this target-doubling shape).
    static func parseTestIdentifiers(_ data: Data) -> [TestIdentifier] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let testNodes = root["testNodes"] as? [[String: Any]]
        else { return [] }

        var found: [TestIdentifier] = []
        func walk(_ node: [String: Any], target: String?) {
            let nodeType = node["nodeType"] as? String
            // `xcresulttool` names a UI test target's own bundle node "UI
            // test bundle", never "Unit test bundle" — confirmed against a
            // real UI-test-only bundle (Phase 5A,
            // `Fixtures/AccessibilityUISubstrate`). Recognizing only "Unit
            // test bundle" here silently dropped every UI test's identifier
            // from enumeration (`currentTarget` stayed `nil`, so the `Test
            // Case` guard below never matched): a UI test target added to
            // `tests.targets` would enumerate as if it had zero tests,
            // starving `selectCoveringTests`'s per-test coverage
            // measurement and any schemata identifier resolution of a UI
            // test's own identifiers, even though the test genuinely ran.
            let currentTarget = isTestBundleNode(nodeType) ? (node["name"] as? String) : target

            if nodeType == "Test Case", let currentTarget,
               let identifier = node["nodeIdentifier"] as? String {
                let qualifiedName = identifier.hasSuffix("()") ? String(identifier.dropLast(2)) : identifier
                found.append(TestIdentifier(target: currentTarget, qualifiedName: qualifiedName))
            }

            for child in (node["children"] as? [[String: Any]]) ?? [] {
                walk(child, target: currentTarget)
            }
        }
        for node in testNodes { walk(node, target: nil) }
        return found
    }

    /// Whether an `xcresulttool` `nodeType` names a test-bundle-level node —
    /// the node whose own `name` is the actual test target's name. Shared
    /// with `XCResultAdapter.ownFailures`, which threads a target name down
    /// for display the identical way. Two node type strings, empirically
    /// confirmed against real result bundles: `"Unit test bundle"` for an
    /// XCTest/Swift Testing unit target, `"UI test bundle"` for an XCUITest
    /// target (see `Fixtures/AccessibilityUISubstrate`, Phase 5A).
    static func isTestBundleNode(_ nodeType: String?) -> Bool {
        nodeType == "Unit test bundle" || nodeType == "UI test bundle"
    }
}

// MARK: - Schemata batch testing

extension XcodeBuildAdapter: SchemataBatchTestable {
    /// Tests several already-embedded schemata tokens — all sharing the one
    /// `artifact` the chunk build produced — in a single `xcodebuild
    /// test-without-building` invocation, reusing `BatchXCTestRunBuilder`
    /// and the same private `runBatchTests`/`runBatchOnDestination` machinery
    /// `BatchTestable.runBatch` below already uses: both ultimately merge
    /// `TestConfigurations` into one `.xctestrun` and read results back via
    /// `XCResultAdapter.classifyBatch`, keyed by configuration name — the
    /// only difference is that every `BatchTestItem` here points at the
    /// *same* `xctestrunPath` instead of each mutant's own, with its own
    /// `environmentVariables` (token/runID/transcript path) standing in for
    /// what isolated mode's separate artifacts already give it for free.
    public func runSchemataTokenBatch(
        _ artifact: BuildArtifact, in workspace: URL, items: [SchemataBatchTokenItem], timeoutSeconds: Double,
        nativeTimeoutAllowanceSeconds: Double?
    ) async -> [MutationID: TestRunResult] {
        guard let xctestrunPath = artifact.xctestrunPath else {
            let failure = TestRunResult(
                status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                diagnosis: "The chunk build produced no .xctestrun, so there is nothing for a token batch to run."
            )
            return Dictionary(uniqueKeysWithValues: items.map { ($0.mutationID, failure) })
        }

        var batchable: [BatchTestItem] = []
        var configurationTestIdentifiers: [String: [String]] = [:]
        var idsByConfigurationName: [String: MutationID] = [:]
        // A caller-contract violation (`SchemataBatchTestable
        // .runSchemataTokenBatch`'s own doc comment: every item must
        // already have a known, non-empty selection), not a normal runtime
        // path — reported directly rather than silently dropped or, worse,
        // fed to `BatchXCTestRunBuilder.build` with an empty
        // `onlyTestingIdentifiers`, which would drop the target entirely
        // and throw `.selectionMatchesNoTarget`, failing every *other* item
        // in the same batch for one item's bad input.
        var results: [MutationID: TestRunResult] = [:]
        for item in items {
            let configurationName = item.mutationID.rawValue
            guard let selectedTests = item.selectedTests, !selectedTests.isEmpty else {
                results[item.mutationID] = TestRunResult(
                    status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                    diagnosis: "This token has no known test selection, so it cannot share a batch — it must run unbatched."
                )
                continue
            }
            batchable.append(BatchTestItem(
                configurationName: configurationName, xctestrunPath: xctestrunPath,
                onlyTestingIdentifiers: Array(selectedTests), environmentVariables: item.environment
            ))
            configurationTestIdentifiers[configurationName] = selectedTests.map(\.onlyTestingArgument)
            idsByConfigurationName[configurationName] = item.mutationID
        }

        func failAllBatchable(_ diagnosis: String) -> [MutationID: TestRunResult] {
            let failure = TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil),
                resultArtifactPath: nil, diagnosis: diagnosis
            )
            for mutationID in idsByConfigurationName.values { results[mutationID] = failure }
            return results
        }

        guard !batchable.isEmpty else { return results }

        let batchData: Data
        do {
            batchData = try BatchXCTestRunBuilder.build(items: batchable)
        } catch {
            return failAllBatchable("The schemata token batch .xctestrun could not be constructed: \(error)")
        }

        let batchDirectory = workspace.appendingPathComponent(".mutantkit/SchemataBatches", isDirectory: true)
        let batchXCTestRunPath = batchDirectory.appendingPathComponent("schemata-batch-\(UUID().uuidString).xctestrun")
        do {
            try FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: true)
            try batchData.write(to: batchXCTestRunPath, options: .atomic)
        } catch {
            return failAllBatchable("The schemata token batch .xctestrun could not be written: \(error)")
        }

        let outcomes = await runBatchTests(
            xctestrunPath: batchXCTestRunPath, in: workspace, timeoutSeconds: timeoutSeconds,
            configurationTestIdentifiers: configurationTestIdentifiers,
            nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
        )

        for (configurationName, mutationID) in idsByConfigurationName {
            results[mutationID] = outcomes[configurationName] ?? TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil),
                resultArtifactPath: nil, diagnosis: "This token's outcome went unreported by the batch classifier."
            )
        }
        return results
    }
}

// MARK: - Batch testing

extension XcodeBuildAdapter: BatchTestable {
    public func runBatch(
        _ items: [BatchMutantItem],
        in workspace: URL,
        timeoutSeconds: Double,
        nativeTimeoutAllowanceSeconds: Double?
    ) async -> [MutationID: TestRunResult] {
        var results: [MutationID: TestRunResult] = [:]
        var batchable: [BatchTestItem] = []
        // Only a narrowed selection can be told apart afterward: the batch
        // bundle's failures are attributed back to a configuration by
        // matching test identifiers, and a configuration left unnarrowed
        // (the full target list, `TestSelecting`'s safe fallback for an
        // unknown attribution) could legitimately run several tests —
        // there would be no way to tell whether a failure among them was a
        // plain assertion or a crash without a distinguishable identifier
        // to match. An item like that runs the ordinary, already-correct
        // unbatched way instead of joining the batch.
        var unbatched: [BatchMutantItem] = []
        // Keyed separately from `BatchTestItem.onlyTestingIdentifiers`
        // because the two serve different consumers of the same selection:
        // `BatchXCTestRunBuilder.build` needs each identifier's owning
        // target so it can narrow (or, when a bundle has none of its own
        // tests selected, drop) each `.xctestrun` target dict independently
        // — see its doc comment for why a target-qualified identifier must
        // never reach a bundle's own bare-`Class/method` `OnlyTestIdentifiers`
        // list. Failure attribution against `xcresulttool`'s batch-wide
        // `testFailures` instead needs the fully target-qualified
        // `TestIdentifier.onlyTestingArgument`, since that is the shape
        // `TestSummaryJSON.Failure.identifier` itself uses.
        var configurationTestIdentifiers: [String: [String]] = [:]

        for item in items {
            if let selectedTests = item.selectedTests, !selectedTests.isEmpty,
               let xctestrunPath = item.artifact.xctestrunPath {
                batchable.append(BatchTestItem(
                    configurationName: item.id.rawValue,
                    xctestrunPath: xctestrunPath,
                    onlyTestingIdentifiers: Array(selectedTests)
                ))
                configurationTestIdentifiers[item.id.rawValue] = selectedTests.map(\.onlyTestingArgument)
            } else {
                unbatched.append(item)
            }
        }

        await withTaskGroup(of: (MutationID, TestRunResult).self) { group in
            for item in unbatched {
                group.addTask {
                    let result = try? await self.runTests(
                        artifact: item.artifact, in: workspace, label: item.id.rawValue,
                        timeoutSeconds: timeoutSeconds
                    )
                    return (item.id, result ?? TestRunResult(
                        status: .infrastructureFailure, summary: nil, command: item.artifact.command,
                        resultArtifactPath: nil, diagnosis: "The mutant's tests could not be run."
                    ))
                }
            }
            for await (id, result) in group {
                results[id] = result
            }
        }

        guard !batchable.isEmpty else { return results }

        let idsByConfigurationName = Dictionary(
            uniqueKeysWithValues: items.compactMap { item -> (String, MutationID)? in
                batchable.contains { $0.configurationName == item.id.rawValue } ? (item.id.rawValue, item.id) : nil
            }
        )

        func failAllBatchable(_ diagnosis: String) {
            for item in batchable {
                guard let id = idsByConfigurationName[item.configurationName] else { continue }
                results[id] = TestRunResult(
                    status: .infrastructureFailure, summary: nil,
                    command: CommandRecording.record(
                        executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil
                    ),
                    resultArtifactPath: nil, diagnosis: diagnosis
                )
            }
        }

        let batchData: Data
        do {
            batchData = try BatchXCTestRunBuilder.build(items: batchable)
        } catch {
            failAllBatchable("The batch .xctestrun could not be constructed: \(error)")
            return results
        }

        let batchDirectory = workspace.appendingPathComponent(".mutantkit/Batches", isDirectory: true)
        let batchXCTestRunPath = batchDirectory.appendingPathComponent("batch-\(UUID().uuidString).xctestrun")
        do {
            try FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: true)
            try batchData.write(to: batchXCTestRunPath, options: .atomic)
        } catch {
            failAllBatchable("The batch .xctestrun could not be written: \(error)")
            return results
        }

        let outcomes = await runBatchTests(
            xctestrunPath: batchXCTestRunPath,
            in: workspace,
            timeoutSeconds: timeoutSeconds,
            configurationTestIdentifiers: configurationTestIdentifiers,
            nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
        )

        for item in batchable {
            guard let id = idsByConfigurationName[item.configurationName] else { continue }
            // Fail-closed even here: `outcomes` is keyed by every name this
            // call was asked about (see `XCResultAdapter.classifyBatch`), so
            // a missing entry only happens if that contract was violated —
            // still handled rather than trusted blindly.
            results[id] = outcomes[item.configurationName] ?? TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "This configuration's outcome went unreported by the batch classifier."
            )
        }

        return results
    }

    /// Leases a device (when the destination needs one) and runs the batch
    /// `.xctestrun`, the same shape `runTests`/`leaseAndRunTests` use for a
    /// single mutant.
    private func runBatchTests(
        xctestrunPath: URL,
        in workspace: URL,
        timeoutSeconds: Double,
        configurationTestIdentifiers: [String: [String]],
        nativeTimeoutAllowanceSeconds: Double? = nil
    ) async -> [String: TestRunResult] {
        func run(destination: String) async -> [String: TestRunResult] {
            await runBatchOnDestination(
                destination, xctestrunPath: xctestrunPath, in: workspace,
                timeoutSeconds: timeoutSeconds, configurationTestIdentifiers: configurationTestIdentifiers,
                nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
            )
        }

        guard destinationNeedsSimulatorLease else {
            return await run(destination: destination())
        }

        do {
            if let device = resolvedDestination?.device {
                return try await simulators.withLease(udid: device.udid) { lease in await run(destination: lease.destination) }
            }
            if let udid = Self.udid(inDestination: destination()) {
                return try await simulators.withLease(udid: udid) { lease in await run(destination: lease.destination) }
            }
            let hint = Self.deviceName(inDestination: destination())
            return try await simulators.withLease(matching: hint) { lease in await run(destination: lease.destination) }
        } catch let error as SimulatorPoolError {
            let failure = TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "No simulator could be leased for this batch: \(error.description)"
            )
            return Dictionary(uniqueKeysWithValues: configurationTestIdentifiers.keys.map { ($0, failure) })
        } catch {
            let failure = TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "The batch could not be leased or run: \(error)"
            )
            return Dictionary(uniqueKeysWithValues: configurationTestIdentifiers.keys.map { ($0, failure) })
        }
    }

    private func runBatchOnDestination(
        _ destination: String,
        xctestrunPath: URL,
        in workspace: URL,
        timeoutSeconds: Double,
        configurationTestIdentifiers: [String: [String]],
        nativeTimeoutAllowanceSeconds: Double? = nil
    ) async -> [String: TestRunResult] {
        let resultBundle = workspace
            .appendingPathComponent(".mutantkit/Results", isDirectory: true)
            .appendingPathComponent("batch-\(UUID().uuidString).xcresult")
        try? FileManager.default.createDirectory(
            at: resultBundle.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        var arguments = [
            "test-without-building",
            "-xctestrun", xctestrunPath.path,
            "-destination", destination,
            "-resultBundlePath", resultBundle.path,
            "-collect-test-diagnostics", "never"
        ]
        // Containment, layered underneath `timeoutSeconds` (the outer,
        // aggregate fail-safe below, unchanged): confirmed empirically that
        // XCTest's own per-test allowance cuts a single hanging
        // configuration off — reported `.timedOut` by
        // `XCResultAdapter.classifyBatch`'s native-timeout branch — without
        // killing this `xcodebuild` invocation or losing its siblings'
        // results, so a batch no longer has to burn its *entire* combined
        // outer budget on one hang before anything is known. `nil` (every
        // caller except isolated wave batching's own multi-member batches,
        // for now) leaves `xcodebuild`'s own default (timeouts disabled)
        // untouched.
        //
        // An earlier version of this code layered a second,
        // `ProcessSupervisor`-level containment mechanism underneath this
        // one — an external, file-growth-based stall watchdog on
        // `-resultStreamPath` — for the case native per-test timeout does
        // not reliably catch (a CPU-bound, non-cooperative hang). Direct
        // content inspection of that stream on a real, long-running hang
        // batch found the hypothesis behind it was wrong: the periodic
        // writes it depended on distinguishing from "stall" turned out to
        // be genuine `testStarted`/timeout events for *additional* tests in
        // the same mutant's own covering-test list, not noise — so no
        // finite margin could ever have made file-growth a reliable "this
        // configuration is truly stuck" signal. Retired for that reason.
        // The real fix for the underlying problem (one mutant's own
        // multiple covering tests each independently hanging) turned out to
        // be a wave-based early-abort for isolated mode and a
        // single-test-only batching eligibility rule for schemata — neither
        // of which touches this function or `ProcessSupervisor`.
        if let nativeTimeoutAllowanceSeconds {
            let allowance = String(format: "%.0f", nativeTimeoutAllowanceSeconds)
            arguments.append(contentsOf: [
                "-test-timeouts-enabled", "YES",
                "-default-test-execution-time-allowance", allowance,
                "-maximum-test-execution-time-allowance", allowance
            ])
        }
        arguments.append(contentsOf: configuration.tests.extraArguments)

        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcodebuild,
                arguments: arguments,
                workingDirectory: workspace,
                timeoutSeconds: timeoutSeconds,
                terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
            )
        } catch {
            let failure = TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild, arguments: arguments, workingDirectory: workspace, result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "Could not launch xcodebuild for the batch: \(error)"
            )
            return Dictionary(uniqueKeysWithValues: configurationTestIdentifiers.keys.map { ($0, failure) })
        }

        let command = CommandRecording.record(
            executable: ToolPaths.xcodebuild, arguments: arguments, workingDirectory: workspace, result: result
        )

        // A batch-wide timeout means none of its configurations produced a
        // trustworthy result — the bundle, if any, reflects an arbitrary
        // subset that happened to finish before the kill, not a complete
        // record. Every configuration in the batch is reported timed out
        // rather than trusting a partial bundle to say which ones did.
        //
        // `isBatchAttributedTimeout` is only true when more than one
        // configuration actually shared this timeout budget: a "batch" of
        // exactly one (the final remainder chunk, or any batch that ends up
        // with a single member) has no attribution ambiguity at all — the
        // timeout unambiguously belongs to that one mutant, the same as a
        // non-batching adapter's timeout does, so `confirmTimeout` must
        // still treat a disagreeing confirmation as `.flaky` rather than
        // trusting it outright.
        if result.timedOut {
            let failure = TestRunResult(
                status: .timedOut, summary: nil, command: command,
                resultArtifactPath: FileManager.default.fileExists(atPath: resultBundle.path) ? resultBundle : nil,
                diagnosis: """
                The batch exceeded its \(String(format: "%.0f", timeoutSeconds))s limit and was \
                terminated before every configuration in it could be confirmed to finish.
                """,
                isBatchAttributedTimeout: configurationTestIdentifiers.count > 1
            )
            return Dictionary(uniqueKeysWithValues: configurationTestIdentifiers.keys.map { ($0, failure) })
        }

        var outcomes = await resultReader.classifyBatch(
            resultBundle: resultBundle, workingDirectory: workspace,
            configurationTestIdentifiers: configurationTestIdentifiers
        )

        // A batch where *every* configuration came back unaccounted for is
        // not "several unrelated bundle read failures" — it is almost
        // always one batch-wide problem (the invocation never really ran).
        // Exit code alone cannot gate this: a batch with genuine failures
        // or crashes in it also exits non-zero, which is why it is not
        // consulted above either. But once every configuration is already
        // unattributed, there is nothing left an exit code could wrongly
        // override, so it is safe to fold in here purely to make the
        // diagnosis legible instead of leaving every mutant blaming a
        // generic "no record" with no way to tell why.
        if !result.succeeded, outcomes.values.allSatisfy({ $0.status == .infrastructureFailure }) {
            let detail = OutputRedactor.redactAndTruncate(result.combinedOutput, limit: 800)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            outcomes = outcomes.mapValues {
                XCResultAdapter.Outcome(
                    status: .infrastructureFailure,
                    summary: $0.summary,
                    diagnosis: "\($0.diagnosis) xcodebuild exited \(result.exitCode): \(detail)"
                )
            }
        }

        let bundleExists = FileManager.default.fileExists(atPath: resultBundle.path)
        return outcomes.mapValues { outcome in
            TestRunResult(
                status: outcome.status, summary: outcome.summary, command: command,
                resultArtifactPath: bundleExists ? resultBundle : nil, diagnosis: outcome.diagnosis
            )
        }
    }
}

// MARK: - .xctestrun

/// Finds the `.xctestrun` that `build-for-testing` produced.
enum XCTestRunLocator {
    /// Searches `Build/Products` for the file.
    ///
    /// Searched, never constructed. The name encodes the scheme, the platform, the
    /// SDK version and the architecture — a real one reads
    /// `Probe-Package_Probe-Package_macosx26.5-arm64.xctestrun` — and every one of
    /// those varies by machine and by Xcode release. Building that string from a
    /// template produces a path that does not exist, and the resulting "file not
    /// found" gets read as a broken project rather than a broken guess.
    static func locate(in productsDirectory: URL, command: CommandRecord) throws -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: productsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        let found = contents.filter { $0.pathExtension == "xctestrun" }.sorted { $0.path < $1.path }

        switch found.count {
        case 1:
            return found[0]
        case 0:
            let siblings = contents.map(\.lastPathComponent).sorted()
            throw BuildFailure(
                kind: .infrastructure,
                diagnosis: """
                build-for-testing succeeded but left no .xctestrun in \
                \(productsDirectory.path). That directory contains \
                \(siblings.isEmpty ? "nothing" : siblings.joined(separator: ", ")). \
                The scheme probably has no test target enabled — check its Test action \
                in Xcode.
                """,
                command: command,
                output: ""
            )
        default:
            let names = found.map(\.lastPathComponent).joined(separator: ", ")
            throw BuildFailure(
                kind: .infrastructure,
                diagnosis: """
                \(found.count) .xctestrun files are present in \(productsDirectory.path) \
                (\(names)) and mutantkit will not guess which one to run. This usually \
                means several test plans or destinations were built; narrow \
                project.destination or the scheme's test plan in mutantkit.yml.
                """,
                command: command,
                output: ""
            )
        }
    }
}

// MARK: - JSON

/// `xcodebuild -list -json`, which reports under `workspace` or `project`
/// depending on what it was pointed at.
enum SchemeListJSON {
    private struct Payload: Decodable {
        struct Container: Decodable {
            let name: String
            let schemes: [String]?
            let targets: [String]?
        }

        let workspace: Container?
        let project: Container?
    }

    static func schemes(from data: Data) -> [String] {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return payload.workspace?.schemes ?? payload.project?.schemes ?? []
    }

    static func targets(from data: Data) -> [String] {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return payload.workspace?.targets ?? payload.project?.targets ?? []
    }
}

// MARK: - Project adapter

/// Pairs the xcodebuild build and test halves for one project kind.
public struct XcodeBuildProjectAdapter: ProjectAdapter {
    public let kind: ProjectKind
    public let build: any BuildAdapter
    public let test: any TestAdapter
    /// The destination resolved once at construction — see
    /// `DestinationResolver`. Surfaced so a caller building a `RunManifest`
    /// can record exactly which device this run is bound to, without
    /// needing to downcast `build`/`test` back to `XcodeBuildAdapter`.
    public let resolvedDestination: ResolvedDestination?
    /// Kept so `prepareSimulatorForRun()` can reach the pool the
    /// underlying adapter owns, without exposing that pool or downcasting
    /// `build`/`test` back to `XcodeBuildAdapter` from the CLI.
    private let simulatorBearingAdapter: XcodeBuildAdapter?

    public init(
        configuration: Configuration,
        kind: ProjectKind,
        projectFile: URL?,
        projectRoot: URL,
        resolvedDestination: ResolvedDestination? = nil,
        workerDevicesByWorkspace: [String: SimulatorDevice]? = nil
    ) {
        self.kind = kind
        self.resolvedDestination = resolvedDestination
        let adapter = XcodeBuildAdapter(
            configuration: configuration,
            kind: kind,
            projectFile: projectFile,
            projectRoot: projectRoot,
            resolvedDestination: resolvedDestination,
            workerDevicesByWorkspace: workerDevicesByWorkspace
        )
        simulatorBearingAdapter = adapter
        build = adapter
        test = adapter
    }

    /// Boots and verifies readiness of the device this run will test on,
    /// if it has one. See `XcodeBuildAdapter.prepareSimulatorForRun`.
    public func prepareSimulatorForRun() async -> SimulatorPreparationRecord {
        if let simulatorBearingAdapter {
            return await simulatorBearingAdapter.prepareSimulatorForRun()
        }
        return SimulatorPreparationRecord(outcome: .notApplicable)
    }
}
