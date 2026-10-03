@testable import CLI
import Foundation
@testable import MutationExecution
@testable import MutationModel
import Testing

/// A run that takes hours has to say what it is doing while it does it. Each
/// case here pins one thing a real run was found to do silently — see each
/// test's own comment for which.
@Suite("Run observability")
struct RunObservabilityTests {
    /// The silence that cost a real project ~100 minutes twice: nothing
    /// distinguished "reusing a measurement" from "about to spend an hour
    /// measuring", and the three reasons a run cannot reuse one are not the
    /// same problem, so they must not read as the same message.
    @Test("Each reason a coverage measurement cannot be reused is named, not reported as a bare miss")
    func coverageCacheMissReasonsAreDistinct() {
        let ordinary = BaselineCoverageMeasurement.missReason(hasKey: true, hasCache: true)
        let noKey = BaselineCoverageMeasurement.missReason(hasKey: false, hasCache: true)
        let noCache = BaselineCoverageMeasurement.missReason(hasKey: false, hasCache: false)

        #expect(Set([ordinary, noKey, noCache]).count == 3)
        // An ordinary miss is expected on a first run and needs no action —
        // it should say so, and say the next run will not pay again.
        #expect(ordinary.contains("miss"))
        #expect(ordinary.contains("later runs"))
        // A missing digest means *no* run will ever cache. That is a real,
        // fixable problem and must not be worded like the expected case.
        #expect(noKey.contains("digest"))
        #expect(!noKey.contains("later runs"))
        #expect(noCache.contains("disabled"))
        // All three are about to spend the time, and all three should say so.
        for reason in [ordinary, noKey, noCache] {
            #expect(reason.contains("measuring per-test coverage"))
        }
    }

    /// The per-test coverage pass, the schemata backend and the isolated
    /// backend all report `[n/total]` progress. Interleaved on one terminal,
    /// unlabelled counters cannot be told apart.
    @Test("Progress counters name what they are counting, and estimate what is left")
    func progressLinesAreLabelledAndEstimate() async {
        let started = Date(timeIntervalSince1970: 0)
        let reporter = MutationProgressReporter(total: 10, label: "per-test coverage", startedAt: started)

        // One of ten done after 60s: nine left at the same rate is ~9m.
        await reporter.recordCompletion(now: started.addingTimeInterval(60))
        let line = await reporter.line(now: started.addingTimeInterval(60))

        #expect(line?.hasPrefix("per-test coverage [1/10] 10%") == true)
        #expect(line?.contains("elapsed 1m00s") == true)
        #expect(line?.contains("ETA ~9m00s") == true)
    }

    @Test("An unlabelled counter stays exactly as it read before labels existed")
    func unlabelledCounterIsUnchanged() async {
        let started = Date(timeIntervalSince1970: 0)
        let reporter = MutationProgressReporter(total: 4, startedAt: started)

        await reporter.recordCompletion(now: started.addingTimeInterval(10))

        #expect(await reporter.line(now: started.addingTimeInterval(10))?.hasPrefix("[1/4] 25%") == true)
    }

    /// A profiling pass is the one place a first run can learn how long this
    /// project's own attribution takes, so the loop must be able to report as
    /// it goes rather than only when it finishes.
    @Test("The attribution loop reports one completion per test, including for unprovable ones")
    func attributionLoopReportsEveryTest() async {
        let tests = (1 ... 5).map { TestIdentifier(target: "T", qualifiedName: "S/test\($0)") }
        let progress = MutationProgressReporter(total: tests.count, label: "per-test coverage")

        _ = await PerTestCoverageAttribution.attribute(
            tests: tests, source: "test", attempts: 1, progress: progress
        ) { test, _ in
            // The third one cannot be measured. Its completion must still be
            // counted, or a pass containing any unprovable test under-reports
            // its own progress and its ETA runs long for the whole rest of
            // the pass.
            test == tests[2] ? nil : CoverageMap(executedLines: ["Sources/Foo.swift": [1]], source: "codecov")
        }

        #expect(await progress.completedCount == tests.count)
    }

    /// `execution.profile` resolving to concrete settings is the one place a
    /// value a user wrote in `mutantkit.yml` gets replaced. The feature list
    /// alone never says so, which leaves the config file looking honoured.
    @Test("A profile that replaces a setting names the setting, with its before and after values")
    func profileOverridesAreNamed() {
        var before = ExecutionSettings()
        before.strategy = .isolated
        before.selectCoveringTests = false
        var after = before
        after.strategy = .schemata
        after.selectCoveringTests = true

        let changes = ExecutionProfileFieldChanges.between(before, after)

        #expect(changes.contains("execution.strategy: isolated → schemata"))
        #expect(changes.contains("execution.selectCoveringTests: false → true"))
    }

    @Test("A profile that replaces nothing says nothing")
    func unchangedSettingsProduceNoOverrides() {
        let settings = ExecutionSettings()

        #expect(ExecutionProfileFieldChanges.between(settings, settings).isEmpty)
    }
}
