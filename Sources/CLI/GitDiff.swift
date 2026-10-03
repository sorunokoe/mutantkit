import Foundation
import MutationExecution
import MutationPlanner

enum GitDiffError: Error, CustomStringConvertible {
    case gitFailed(base: String, message: String)

    var description: String {
        switch self {
        case let .gitFailed(base, message):
            "Could not diff against '\(base)': \(message)"
        }
    }
}

/// Reads changed line ranges from git.
///
/// This lives in the CLI rather than in `MutationPlanner` so that the planner
/// stays subprocess-free and testable: it takes a `DiffScope` as data and does
/// not care whether git, a CI provider, or a fixture produced it.
enum GitDiff {
    /// Line ranges changed in the working tree relative to `base`.
    ///
    /// Uses `--unified=0` so each hunk covers only changed lines: with the
    /// default context, a hunk would claim three untouched lines either side and
    /// a PR-scoped run would mutate code the change never touched.
    static func changedLines(since base: String, in root: URL) async throws -> DiffScope {
        let result = try await ProcessSupervisor.run(
            executable: "/usr/bin/git",
            arguments: ["diff", "--relative", "--unified=0", "--no-color", "--no-ext-diff", base, "--", "*.swift"],
            workingDirectory: root,
            timeoutSeconds: 120
        )

        guard result.succeeded else {
            let message = String(decoding: result.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitDiffError.gitFailed(base: base, message: message.isEmpty ? "git exited \(result.exitCode)" : message)
        }

        return DiffScope(changedLines: parse(String(decoding: result.standardOutput, as: UTF8.self)))
    }

    /// Parses `+++ b/<path>` headers and `@@ -a,b +c,d @@` hunk headers.
    ///
    /// Only the `+` side matters: a mutation is planned against the *new* file,
    /// so the ranges must be in new-file coordinates.
    static func parse(_ diff: String) -> [String: [Range<Int>]] {
        var changed: [String: [Range<Int>]] = [:]
        var currentFile: String?

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++ ") {
                let path = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                // `/dev/null` means the file was deleted; there is nothing to mutate.
                currentFile = path == "/dev/null" ? nil : String(path.hasPrefix("b/") ? path.dropFirst(2) : path[...])
                continue
            }

            guard line.hasPrefix("@@"), let file = currentFile else { continue }
            guard let range = parseHunkRange(String(line)) else { continue }
            changed[file, default: []].append(range)
        }

        return changed.mapValues { $0.sorted { $0.lowerBound < $1.lowerBound } }
    }

    /// Extracts the new-file range from `@@ -12,3 +14,5 @@`.
    ///
    /// A count of 0 means a pure deletion — nothing exists at that location in
    /// the new file, so it contributes no mutable lines.
    private static func parseHunkRange(_ header: String) -> Range<Int>? {
        guard let plusToken = header
            .split(separator: " ")
            .first(where: { $0.hasPrefix("+") })
        else { return nil }

        let numbers = plusToken.dropFirst().split(separator: ",")
        guard let start = Int(numbers[0]) else { return nil }
        let count = numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1
        guard count > 0 else { return nil }

        return start ..< (start + count)
    }
}
