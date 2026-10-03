import Foundation

/// Reports "N/total" progress to stderr as mutants finish. An actor, not a
/// lock — like `OperationalIssueLog`, completions come from the same
/// concurrent task group that runs `MutationRunner.finalize` for each
/// mutation, so recording a completion has to be safe to call concurrently.
///
/// A long real-project run (hundreds of mutants, each its own build/test
/// cycle) previously gave a human watching it no signal beyond silence
/// until the final report — this exists so "is it stuck or just slow" has
/// an answer without reaching for `wc -l` on the checkpoint file.
public actor MutationProgressReporter {
    private let total: Int
    private let label: String
    private let startedAt: Date
    private var completed = 0

    /// - Parameter label: what is being counted, when that is not obvious
    ///   from context. A run reports more than one kind of progress — the
    ///   per-test coverage pass counts tests, the schemata backend counts
    ///   chunks, the isolated backend counts mutants — and two unlabelled
    ///   `[12/50]` streams interleaved on one terminal cannot be told apart.
    public init(total: Int, label: String = "", startedAt: Date = Date()) {
        self.total = total
        self.label = label
        self.startedAt = startedAt
    }

    /// How many completions have been recorded so far.
    public var completedCount: Int { completed }

    public func recordCompletion(now: Date = Date()) {
        completed += 1
        guard let line = line(now: now) else { return }
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// The line `recordCompletion` writes, or `nil` when there is nothing to
    /// report. Pulled out as a pure function — the same split
    /// `DryRunCommand.passedOutput` makes — so the format, the label and the
    /// ETA arithmetic are directly testable, rather than only observable by
    /// watching a real hours-long run's stderr.
    func line(now: Date) -> String? {
        guard total > 0 else { return nil }

        let elapsed = now.timeIntervalSince(startedAt)
        let percent = Int((Double(completed) / Double(total) * 100).rounded())
        // ETA extrapolates linearly from the mean per-unit time so far —
        // a rough estimate, not a promise; the point is "roughly how much
        // longer", not a precise countdown. It is also the only answer a
        // first run gets to "how long will this take", since the cost
        // depends on the project's own suite, which nothing can know in
        // advance of measuring it.
        let etaText = completed > 0
            ? Self.formatDuration(elapsed / Double(completed) * Double(total - completed))
            : "?"

        let prefix = label.isEmpty ? "" : "\(label) "
        return "\(prefix)[\(completed)/\(total)] \(percent)% — elapsed \(Self.formatDuration(elapsed)), ETA ~\(etaText)\n"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 { return String(format: "%dh%02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm%02ds", minutes, secs) }
        return "\(secs)s"
    }
}
