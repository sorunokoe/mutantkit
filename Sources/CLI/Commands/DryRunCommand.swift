import AppleBuildAdapters
import ArgumentParser
import Foundation
import MutationExecution
import MutationModel

/// Builds and tests the unmutated project exactly once using the same adapters,
/// destination resolution and timeout configuration a mutation run will use.
/// This is Stryker-style dry-run validation: fail before planning hundreds of
/// mutants when the baseline environment itself is not runnable.
struct DryRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dry-run",
        abstract: "Build and test the unmutated baseline once without executing mutants."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var overrides: OverrideOptions

    func run() async throws {
        let root = common.resolvedProjectRoot
        var settings = try ConfigurationLoader.load(explicitPath: common.configPath, projectRoot: root)
        try overrides.apply(to: &settings)

        try ConfigurationPreflight.run(settings)

        let resolution = try await AppleAdapterFactory.resolve(configuration: settings, in: root)
        print("Project: \(resolution.detection.kind.rawValue) — \(resolution.detection.reason)")

        // Same preflight `run` performs before its baseline, and for the same
        // reasons: a simulator that cannot pass `bootstatus` should fail here,
        // cheaply and with an obvious cause, rather than surface as a confusing
        // build/test failure below. See RunCommand for the fuller rationale.
        let simulatorPreparation = await resolution.adapter.prepareSimulatorForRun()
        switch simulatorPreparation.outcome {
        case .notApplicable:
            break
        case .alreadyBooted, .prepared:
            print("Simulator ready (\(simulatorPreparation.outcome.rawValue)): \(simulatorPreparation.name ?? "unknown device").")
        case .failed:
            // v0.5 Stable Contracts: diagnostics go to stderr, not stdout.
            FileHandle.standardError.write(Data(
                "Simulator \(simulatorPreparation.name ?? "(unknown)") did not pass bootstatus: \(simulatorPreparation.detail ?? "unknown failure").\n"
                    .utf8
            ))
            throw ExitCode(MutantKitExit.operationalError)
        }

        let runDirectory = root.appendingPathComponent(".mutantkit")
        let lockRoot = runDirectory.appendingPathComponent("run-locks")
        // Same lock namespace `run` uses: a dry run against a destination a
        // real `mutantkit run` already owns is exactly the same resource
        // contention the lock exists to prevent, not a different case.
        let runLock = try RunIsolationLock.acquire(
            projectRoot: root,
            lockRoot: lockRoot,
            destination: settings.project.destination ?? "auto"
        )
        defer { runLock.release() }
        let resourceSnapshot = ResourceSnapshot.capture(lockRoot: lockRoot)
        print("""
        \(resourceSnapshot.loadAverage1Minute.formatted(.number.precision(.fractionLength(2))))/\
        \(resourceSnapshot.loadAverage5Minute.formatted(.number.precision(.fractionLength(2))))/\
        \(resourceSnapshot.loadAverage15Minute.formatted(.number.precision(.fractionLength(2)))) load, \
        \(resourceSnapshot.freeMemoryBytes.map { "\($0 / 1_048_576) MB free" } ?? "memory unknown")
        """)

        let scratch = root.appendingPathComponent(".mutantkit/dry-run")
        let workspaces = try WorkspaceManager(
            projectRoot: root, scratchRoot: scratch, linkSiblings: settings.project.linkSiblings ?? []
        )
        let id = "dry-run-baseline"
        let expected = scratch.appendingPathComponent(WorkspaceManager.directoryName(for: id))
        if FileManager.default.fileExists(atPath: expected.path) {
            try await workspaces.destroySandbox(at: expected)
        }
        let sandbox = try await workspaces.createSandbox(id: id)

        do {
            print("Building baseline…")
            let artifact: BuildArtifact
            do {
                artifact = try await resolution.adapter.build.buildBaseline(in: sandbox)
            } catch let failure as BuildFailure {
                // v0.5 Stable Contracts: diagnostics go to stderr, not
                // stdout — both lines here are the failure report itself
                // (why it failed, and the exact command that failed), not
                // separate success output, so both move together.
                FileHandle.standardError.write(Data("Dry run build failed: \(failure.diagnosis)\n".utf8))
                FileHandle.standardError.write(Data("\(failure.command.displayString)\n".utf8))
                throw ExitCode(MutantKitExit.operationalError)
            }

            print("Testing baseline…")
            let result = try await resolution.adapter.test.runBaseline(
                artifact,
                in: sandbox,
                timeoutSeconds: settings.timeouts.baselineSeconds
            )

            guard result.status == .passed else {
                // v0.5 Stable Contracts: diagnostics go to stderr, not
                // stdout — same reasoning as the build-failure case above.
                FileHandle.standardError.write(Data("Dry run failed: \(result.status.rawValue) — \(result.diagnosis)\n".utf8))
                FileHandle.standardError.write(Data("\(result.command.displayString)\n".utf8))
                throw ExitCode(MutantKitExit.operationalError)
            }

            // v0.5 Stable Contracts: diagnostics go to stderr, not stdout.
            let passed = Self.passedOutput(for: result.summary)
            print(passed.stdoutLine)
            if let warning = passed.stderrWarning { FileHandle.standardError.write(Data(warning.utf8)) }
            print("Build: \(artifact.command.displayString)")
            print("Test:  \(result.command.displayString)")
            try? await workspaces.destroySandbox(at: sandbox)
        } catch {
            try? await workspaces.destroySandbox(at: sandbox)
            throw error
        }
    }

    /// What `run()` prints/warns for a passed baseline — pulled out as a
    /// pure function (mirroring `countsDescription` just below) so the
    /// decision itself is directly unit-testable. `run()`'s own body talks
    /// to real adapters/sandboxes and cannot be unit-tested at all, which
    /// previously left this branching logic effectively untested — a real
    /// gap `SonarCloud`'s new-code coverage gate on this PR actually
    /// caught (20% on this file, 12 of 15 new lines uncovered).
    ///
    /// `stderrWarning`, when present, is its own separate line rather than
    /// folded into `stdoutLine`: the baseline itself did pass, so burying
    /// "structured counts were not available" inside a "passed (...)"
    /// clause reads as a minor caveat on good news, not the real reporting
    /// gap it is.
    struct PassedOutput: Equatable {
        let stdoutLine: String
        let stderrWarning: String?
    }

    static func passedOutput(for summary: TestOutcomeSummary?) -> PassedOutput {
        guard let summary else {
            return PassedOutput(
                stdoutLine: "Dry run passed.",
                stderrWarning: "warning: \(countsDescription(for: nil)). Mutation execution can " +
                    "proceed, but test-count reporting will be unavailable for this run.\n"
            )
        }
        return PassedOutput(stdoutLine: "Dry run passed (\(Self.countsDescription(for: summary))).", stderrWarning: nil)
    }

    /// The confidence-building count `dry-run` exists to show, whenever the
    /// adapter that ran the baseline actually has one.
    ///
    /// `result.summary` already carries a real, structured count whenever one
    /// exists — every `.xcresult`-backed adapter run (Xcode/xcodebuild
    /// destinations) always attaches one for a `.passed` result, since
    /// `XCResultAdapter.Outcome.summary` is non-optional. SwiftPM's `swift
    /// test` is the one case that can genuinely have none: SwiftPM only
    /// writes an XCTest xunit report in `--parallel` mode (see
    /// `SwiftPackageMacOSAdapter.runTests`'s own comment on why that stays
    /// opt-in — a flaky parallel-unsafe suite would otherwise misclassify a
    /// mutant as killed), so a passing, purely-XCTest, non-parallel package
    /// run leaves no structured report of any kind to read a count from. That
    /// is a real absence of data, not a missed extraction — reporting a count
    /// there would mean inventing one from unstructured `swift test` stdout,
    /// which this tool never treats as trustworthy data (see `XCResultAdapter`'s
    /// and `XUnitParser`'s own doc comments). So the vaguer message is kept,
    /// but only for that genuinely-unmeasured case.
    static func countsDescription(for summary: TestOutcomeSummary?) -> String {
        guard let summary else {
            return "test counts unavailable — no structured test report was written for this run"
        }
        return "\(summary.passed) passed, \(summary.failed) failed of \(summary.total)"
    }
}
