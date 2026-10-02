import Foundation
import MutationModel

/// The per-test coverage pass's shared machinery: the loop that turns one
/// isolated run per test into a reverse index, and the reporting of what that
/// loop could not prove.
///
/// Shared rather than written once per adapter because the policy here — how
/// many times a test is retried before it is given up on, and what happens to
/// a test that is given up on — is a correctness decision, not an adapter
/// detail. `XcodeBuildAdapter` and `SwiftPackageMacOSAdapter` differ only in
/// how one test is run and how its coverage is read; everything either of
/// them does with the result is identical, and two copies of it is exactly
/// how the two adapters would drift into disagreeing about what a partial
/// map means.
public enum PerTestCoverageAttribution {
    /// Runs `attempt` for each test in turn and inverts what it reports into
    /// `file -> line -> tests`. A test `attempt` cannot measure, after
    /// `attempts` tries, lands in `PerTestCoverageMap.unattributedTests`
    /// rather than invalidating every other test's measurement — see that
    /// type's own doc comment for why carrying it is what makes the result
    /// safe, and why dropping it silently would not be.
    ///
    /// `attempts` is 2, not 1, because the failures actually observed in the
    /// field are transient infrastructure ones — the first real-world
    /// instance was an `.xcresult` written without its `database.sqlite3`, at
    /// test 575 of 647 — while a genuinely order-dependent test fails the
    /// retry exactly as deterministically as the first attempt. The retry
    /// therefore only ever costs time for the failure class it cannot fix.
    ///
    /// `nil` when nothing at all could be attributed, which every caller
    /// already treats as "no per-test coverage": every mutant runs the full
    /// configured test list, the safe, unrestricted default.
    ///
    /// - Parameter attempt: runs one test in isolation with coverage enabled
    ///   and returns the lines it executed, or `nil` if that could not be
    ///   established. Called with the 1-based attempt number so a retry can
    ///   avoid reusing the failed attempt's own scratch paths — reading a
    ///   retry back out of the half-written state being retried past is
    ///   precisely the failure this retry exists to get past.
    public static func attribute(
        tests: [TestIdentifier],
        source: String,
        attempts: Int = 2,
        progress: MutationProgressReporter? = nil,
        attempt: (TestIdentifier, Int) async -> CoverageMap?
    ) async -> PerTestCoverageMap? {
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        var unattributedTests: Set<TestIdentifier> = []

        for test in tests {
            var measured: CoverageMap?
            for attemptNumber in 1 ... attempts {
                measured = await attempt(test, attemptNumber)
                if measured != nil { break }
            }
            if let measured {
                for (file, lines) in measured.executedLines {
                    for line in lines {
                        coveringTests[file, default: [:]][line, default: []].insert(test)
                    }
                }
            } else {
                unattributedTests.insert(test)
            }
            // Awaited in the loop body rather than deferred into a detached
            // task: this is the only signal a human has that an hour-plus
            // pass is progressing at all, so it has to arrive in order, as
            // each test finishes — not whenever a scheduler gets to it.
            await progress?.recordCompletion()
        }

        guard !coveringTests.isEmpty else { return nil }
        return PerTestCoverageMap(
            coveringTests: coveringTests, source: source, unattributedTests: unattributedTests
        )
    }

    /// Reports a pass that finished without being able to prove every test,
    /// to stderr (for a human watching the run live) and to
    /// `RunReport.operationalIssues` (for a reader of `report.json`
    /// afterward) — the same two places every other best-effort fact in this
    /// tool is recorded, and for the same reason: the run's score does not
    /// depend on it, but it must not silently vanish.
    ///
    /// Worth reporting rather than passing over in silence, because the
    /// alternative was measured in the field. The pass is the single most
    /// expensive thing a baseline does (~100 minutes on a real 647-test iOS
    /// project), the run still charges for it in
    /// `BaselineRecord.profilingDurationSeconds`, and the all-or-nothing
    /// predecessor said nothing at all when one unprovable test made it throw
    /// the entire measurement away. That silence is exactly how that project
    /// came to pay the full pass on two consecutive runs while every mutant
    /// still ran the whole suite and nothing was ever cached — a fact its
    /// owner could only discover by watching `-only-testing:` invocations go
    /// by in `ps`.
    ///
    /// A complete pass reports nothing: this is a degradation notice, not a
    /// progress line.
    public static func report(_ coverage: PerTestCoverageMap, to log: OperationalIssueLog?) async {
        guard !coverage.isComplete else { return }
        let named = coverage.unattributedTests.map(\.onlyTestingArgument).sorted()
        let diagnosis = """
        Per-test coverage attribution is incomplete: \(named.count) test(s) could not be proven in isolation, so \
        nothing is known about what they cover. Every mutant's test selection includes those tests, and no mutant \
        is classified noCoverage from this map, so score and integrity are unaffected — the run is only slower \
        than a complete attribution would have made it. Unproven: \
        \(named.prefix(unprovenTestsNamed).joined(separator: ", "))\
        \(named.count > unprovenTestsNamed ? " (+\(named.count - unprovenTestsNamed) more)" : "").
        """
        FileHandle.standardError.write(Data("warning: \(diagnosis)\n".utf8))
        await log?.append(
            OperationalIssue(severity: .warning, kind: .perTestCoverageIncomplete, mutationID: nil, diagnosis: diagnosis)
        )
    }

    /// How many unproven tests the diagnosis names before summarising the
    /// rest as a count. Enough to act on (a cluster in one suite is visible
    /// immediately) without turning a systemic failure — where hundreds of
    /// tests are unproven — into a report field megabytes long.
    private static let unprovenTestsNamed = 10
}
