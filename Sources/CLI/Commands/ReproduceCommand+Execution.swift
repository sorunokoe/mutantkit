import AppleBuildAdapters
import ArgumentParser
import Foundation
import MutationExecution
import MutationModel
import SwiftFrontend

/// Sandbox setup, mutation application, execution resolution, and
/// build-and-test for `ReproduceCommand`.
///
/// Moved verbatim out of `ReproduceCommand.swift` (whose `run()` carried
/// both of that file's baseline entries: `cyclomatic_complexity` 13 and a
/// 135-line body) following the same convention as
/// `RunCommand+Reports.swift`: an `extension ReproduceCommand` in its own
/// file, purely for size. Members are `internal`, not `private`, for
/// exactly that reason — their only caller, `run()`, lives in
/// `ReproduceCommand.swift`.
extension ReproduceCommand {
    /// A fresh, deterministic sandbox for one reproduction — moved with its
    /// own comment from `run()`.
    ///
    /// Deliberately outside `.mutantkit/sandboxes`: the runner destroys those,
    /// and the whole point of this command is a directory that survives.
    func prepareFreshSandbox(root: URL, mutationID: String, linkSiblings: [String] = []) async throws -> URL {
        let sandboxRoot = root.appendingPathComponent(".mutantkit/reproduce")
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: sandboxRoot, linkSiblings: linkSiblings)

        // `WorkspaceManager.createSandbox` is intentionally incremental: it may
        // keep destination files whose size and mtime match, which is useful for
        // normal mutation throughput but wrong for an independent reproduction.
        // A previous reproduce attempt may contain mutated source, DerivedData,
        // generated files or test artifacts that no longer correspond to the
        // current tree. Reproduction therefore always starts by deleting the
        // deterministic sandbox path before repopulating it.
        let expectedSandbox = sandboxRoot.appendingPathComponent(
            WorkspaceManager.directoryName(for: mutationID)
        )
        if FileManager.default.fileExists(atPath: expectedSandbox.path) {
            try await workspaces.destroySandbox(at: expectedSandbox)
        }

        let sandbox = try await workspaces.createSandbox(id: mutationID)
        print("Sandbox: \(sandbox.path) (fresh)")
        return sandbox
    }

    /// Applies one mutation in place and prints the diff — moved with its
    /// own comment from `run()`.
    func applyAndReportMutation(_ point: MutationPoint, fileAt target: URL) throws -> AppliedMutation {
        let applied: AppliedMutation
        do {
            applied = try MutationApplication.applyInPlace(point, fileAt: target)
        } catch let error as ApplicationError {
            print("\nCould not apply the mutation: \(error.description)")
            if error.verification != nil {
                print("""

                The anchor no longer matches, so nothing was written. The mutation is not \
                relocated to a nearby offset — that is how a tool ends up mutating the wrong \
                expression. Re-run `mutantkit plan` against the current source.
                """)
            }
            throw ExitCode(MutantKitExit.integrityFailure)
        }

        print("""

        Applied \(point.id) to \(point.file)

        \(applied.evidence.sourceDiff)
        """)
        return applied
    }

    /// The adapter resolution and mutant timeout this reproduction builds
    /// and tests against — moved with its own branches from `run()`.
    func resolveExecutionContext(
        settings: Configuration, loadedPlan: MutationPlan, root: URL
    ) async throws -> (resolution: AppleAdapterFactory.Resolution, mutantTimeoutSeconds: Double) {
        if replay {
            let runDirectory = root.appendingPathComponent(".mutantkit")
            let manifestURL = RunManifest.url(runDirectory: runDirectory, workUnitID: loadedPlan.workUnitID)
            let manifest: RunManifest
            do {
                manifest = try RunManifest.read(from: manifestURL)
            } catch {
                print("""

                No run manifest at \(manifestURL.path): \(error)
                --replay reproduces a specific `mutantkit run`'s exact conditions, so it needs \
                that run's manifest. Run `mutantkit run` for this plan first, or use --run to \
                build and test against the current environment's own resolution instead.
                """)
                throw ExitCode(MutantKitExit.operationalError)
            }
            print("""

            Replaying \(manifest.workUnitID)'s run from \(manifest.startedAt): \
            \(manifest.resolvedDestination?.destinationArgument ?? "(no destination to pin)"), \
            \(String(format: "%.0f", manifest.mutantTimeoutSeconds))s timeout.
            """)
            if let resolvedDestination = manifest.resolvedDestination {
                return try await (
                    AppleAdapterFactory.resolve(configuration: settings, in: root, replaying: resolvedDestination),
                    manifest.mutantTimeoutSeconds
                )
            } else {
                return try await (
                    AppleAdapterFactory.resolve(configuration: settings, in: root),
                    manifest.mutantTimeoutSeconds
                )
            }
        } else {
            return try await (
                AppleAdapterFactory.resolve(configuration: settings, in: root),
                TimeoutController(settings: settings.timeouts).mutantLimitSeconds
            )
        }
    }

    /// Builds the mutant, runs its tests, and prints the raw result — moved
    /// with its own comments from `run()`.
    func buildTestAndReport(
        resolution: AppleAdapterFactory.Resolution,
        applied: AppliedMutation,
        point: MutationPoint,
        sandbox: URL,
        mutantTimeoutSeconds: Double
    ) async throws {
        print("Building…")
        let artifact: BuildArtifact
        do {
            artifact = try await resolution.adapter.build.buildMutant(applied, in: sandbox)
        } catch let failure as BuildFailure {
            // Display-only, not a scored verdict — this command builds one
            // mutant in isolation with no baseline to compare it against
            // (see the comment below), so it never reaches
            // `MutationVerdictVerifier`; the outcome names here are just the
            // ones a real build failure of each kind would eventually earn.
            let outcome: MutationOutcome = switch failure.kind {
            case .compilationError: .unviable
            case .infrastructure, .timedOut: .infrastructureFailure
            }
            print("\nOutcome: \(outcome.displayName)\n\(failure.diagnosis)")
            return
        }

        print("Testing…")
        let result = try await resolution.adapter.test.runMutant(
            point,
            artifact: artifact,
            in: sandbox,
            timeoutSeconds: mutantTimeoutSeconds
        )

        // Reported as the raw test status, not as a scored outcome. Scoring
        // needs activation evidence, and activation evidence needs a baseline
        // build to compare against — which this command deliberately does not
        // do. Synthesizing one here would mean printing a verdict backed by a
        // comparison that never happened, which is exactly the habit this tool
        // exists to break. `mutantkit run` is what produces scores.
        let counts = result.summary.map { summary in
            " — \(summary.passed) passed, \(summary.failed) failed of \(summary.total)"
        } ?? " — counts unavailable"

        print("""

        Tests: \(result.status.rawValue)\(counts)
        \(result.diagnosis)
        """)

        if let failing = result.summary?.failingTests, !failing.isEmpty {
            print("\nFailing tests")
            for test in failing.prefix(10) {
                print("  \(test)")
            }
        }

        print("""

        Build: \(artifact.command.displayString)
        Test:  \(result.command.displayString)

        Sandbox kept at \(sandbox.path)
        """)
    }
}
