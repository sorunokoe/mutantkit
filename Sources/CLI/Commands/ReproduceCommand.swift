import ArgumentParser
import Foundation
import MutationModel

/// Rebuilds one mutant, alone, in a sandbox you can keep.
///
/// A surviving mutant is a claim about your tests. This is how that claim is
/// checked by hand: the same plan, the same anchor, one mutation, a directory
/// left on disk to poke at.
struct ReproduceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reproduce",
        abstract: "Apply one mutation to a sandbox so it can be investigated by hand."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var overrides: OverrideOptions

    @Argument(help: "The mutation ID to reproduce.")
    var mutationID: String

    @Option(name: .long, help: "The plan containing the mutation.")
    var plan = "plan.json"

    @Flag(name: .long, help: "Also build and run the tests against the mutant.")
    var run = false

    @Flag(name: .long, help: """
    Build and test against the exact destination and timeout the original \
    `mutantkit run` recorded (see `RunManifest`), instead of re-resolving and \
    re-measuring them now. Implies --run.
    """)
    var replay = false

    func run() async throws {
        let root = common.resolvedProjectRoot
        var settings = try ConfigurationLoader.load(explicitPath: common.configPath, projectRoot: root)
        try overrides.apply(to: &settings)

        try ConfigurationPreflight.run(settings)

        let loadedPlan = try loadPlan()
        let id = MutationID(rawValue: mutationID)

        guard let point = loadedPlan.mutations.first(where: { $0.id == id }) else {
            // v0.5 Stable Contracts: diagnostics go to stderr, not stdout.
            FileHandle.standardError.write(Data("No mutation \(id) in \(plan).\n".utf8))
            throw ExitCode(MutantKitExit.operationalError)
        }

        let sandbox = try await prepareFreshSandbox(
            root: root, mutationID: point.id.rawValue, linkSiblings: settings.project.linkSiblings ?? []
        )

        let target = sandbox.appendingPathComponent(point.file)
        let applied = try applyAndReportMutation(point, fileAt: target)

        guard run || replay else {
            print("""
            The sandbox is intact. Investigate it directly, or re-run with --run to build \
            and test the mutant here, or --replay to reproduce the original run's exact \
            destination and timeout.
            """)
            return
        }

        let execution = try await resolveExecutionContext(settings: settings, loadedPlan: loadedPlan, root: root)

        // `reproduce`/`--replay` are standalone investigations, not part of a
        // `mutantkit run`'s lifecycle, so they have no manifest of their own to
        // carry a snapshot in — but a surprising result found here is at
        // least as likely to need "what was the machine doing" evidence as
        // one found during a full run. Printed rather than written to a
        // file: nothing here claims to be reproducible evidence the way a
        // `RunManifest` does, only a record of what this one attempt saw.
        let snapshot = ResourceSnapshot.capture(lockRoot: root.appendingPathComponent(".mutantkit/run-locks"))
        print("""

        \(snapshot.loadAverage1Minute.formatted(.number.precision(.fractionLength(2))))/\
        \(snapshot.loadAverage5Minute.formatted(.number.precision(.fractionLength(2))))/\
        \(snapshot.loadAverage15Minute.formatted(.number.precision(.fractionLength(2)))) load, \
        \(snapshot.freeMemoryBytes.map { "\($0 / 1_048_576) MB free" } ?? "memory unknown"), \
        \(snapshot.runLockFilesPresent) run lock(s) present
        """)

        try await buildTestAndReport(
            resolution: execution.resolution, applied: applied, point: point,
            sandbox: sandbox, mutantTimeoutSeconds: execution.mutantTimeoutSeconds
        )
    }

    /// Pulled out of `run()` purely to keep that function under this
    /// project's `function_body_length` limit — `MutantKitExit.onFailure`
    /// is what actually matters here: a malformed or unreadable plan file
    /// must exit with `MutantKitExit.operationalError` explicitly, not
    /// whatever `ArgumentParser`'s own default failure handling happens to
    /// pick.
    private func loadPlan() throws -> MutationPlan {
        try MutantKitExit.onFailure {
            try MutationPlan.decode(from: Data(contentsOf: URL(fileURLWithPath: plan)))
        }
    }
}
