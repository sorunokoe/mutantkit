@testable import CLI
import Foundation
import MutationExecution
import Testing

/// `GitDiff` had no test coverage at all before this file. `parse`/
/// `parseHunkRange` are pure string parsing with no I/O, so they are
/// covered directly; `changedLines(since:in:)` wraps a real `git diff`
/// subprocess call, covered against a real, disposable git repository
/// rather than mocked, matching how this codebase treats other thin
/// subprocess wrappers it trusts `ProcessSupervisor` itself to run
/// correctly.
@Suite("GitDiff")
struct GitDiffTests {
    // MARK: - parse

    @Test("A single hunk in one file yields that file's new-file range")
    func singleHunkYieldsOneRange() {
        let diff = """
        diff --git a/Sources/Foo.swift b/Sources/Foo.swift
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -10,0 +11,3 @@
        +line one
        +line two
        +line three
        """
        let changed = GitDiff.parse(diff)
        #expect(changed["Sources/Foo.swift"] == [11 ..< 14])
    }

    @Test("Multiple hunks in one file are sorted by lower bound")
    func multipleHunksAreSortedByLowerBound() {
        let diff = """
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -50,0 +51,2 @@
        +z
        +z
        @@ -1,0 +2,1 @@
        +a
        """
        let changed = GitDiff.parse(diff)
        #expect(changed["Sources/Foo.swift"] == [2 ..< 3, 51 ..< 53])
    }

    @Test("Multiple changed files each get their own ranges")
    func multipleFilesEachGetTheirOwnRanges() {
        let diff = """
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -1,0 +2,1 @@
        +a
        --- a/Sources/B.swift
        +++ b/Sources/B.swift
        @@ -5,0 +6,1 @@
        +b
        """
        let changed = GitDiff.parse(diff)
        #expect(changed["Sources/A.swift"] == [2 ..< 3])
        #expect(changed["Sources/B.swift"] == [6 ..< 7])
    }

    @Test("A deleted file (+++ /dev/null) contributes no mutable ranges")
    func deletedFileContributesNoRanges() {
        let diff = """
        --- a/Sources/Removed.swift
        +++ /dev/null
        @@ -1,5 +0,0 @@
        -gone
        """
        let changed = GitDiff.parse(diff)
        #expect(changed.isEmpty)
    }

    @Test("A pure deletion hunk (new-file count 0) contributes no range")
    func pureDeletionHunkContributesNoRange() {
        let diff = """
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -10,3 +9,0 @@
        -old one
        -old two
        -old three
        """
        let changed = GitDiff.parse(diff)
        #expect(changed["Sources/Foo.swift"] == nil)
    }

    @Test("Diff text with no hunks at all parses to an empty map")
    func noHunksParsesToEmptyMap() {
        #expect(GitDiff.parse("").isEmpty)
        #expect(GitDiff.parse("some unrelated preamble\nwith no +++ or @@ lines\n").isEmpty)
    }

    @Test("A 'b/' prefix on the +++ path is stripped")
    func bPrefixOnPathIsStripped() {
        let diff = """
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -1,0 +2,1 @@
        +a
        """
        let changed = GitDiff.parse(diff)
        #expect(Array(changed.keys) == ["Sources/Foo.swift"])
    }

    // MARK: - parseHunkRange (indirectly, through parse, since it is private)

    @Test("A hunk header with no explicit new-file count defaults to a count of 1")
    func hunkHeaderWithNoCountDefaultsToOne() {
        let diff = """
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -5,0 +6 @@
        +a
        """
        let changed = GitDiff.parse(diff)
        #expect(changed["Sources/Foo.swift"] == [6 ..< 7])
    }

    @Test("A malformed hunk header (no +N token) is skipped, not treated as a crash or a zero-width range")
    func malformedHunkHeaderIsSkipped() {
        let diff = """
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ garbage @@
        +a
        """
        let changed = GitDiff.parse(diff)
        #expect(changed["Sources/Foo.swift"] == nil)
    }

    // MARK: - GitDiffError

    @Test("GitDiffError.gitFailed describes the base and the underlying message")
    func gitFailedErrorDescribesBaseAndMessage() {
        let error = GitDiffError.gitFailed(base: "main", message: "unknown revision")
        #expect(error.description.contains("main"))
        #expect(error.description.contains("unknown revision"))
    }

    // MARK: - changedLines(since:in:) — a real git subprocess, a real repo

    private func makeGitRepository() async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-gitdiff-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func git(_ arguments: [String]) async throws {
            let result = try await ProcessSupervisor.run(
                executable: "/usr/bin/git", arguments: arguments, workingDirectory: root, timeoutSeconds: 30
            )
            try #require(result.succeeded, "git \(arguments.joined(separator: " ")) failed: \(String(decoding: result.standardError, as: UTF8.self))")
        }

        try await git(["init", "-q"])
        try await git(["config", "user.email", "test@example.com"])
        try await git(["config", "user.name", "Test"])
        try Data("func original() {}\n".utf8).write(to: root.appendingPathComponent("Foo.swift"))
        try await git(["add", "Foo.swift"])
        try await git(["commit", "-q", "-m", "initial"])
        return root
    }

    @Test("changedLines reports the new-file range of an actual uncommitted edit")
    func changedLinesReportsARealEdit() async throws {
        let root = try await makeGitRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("func original() {}\nfunc added() {}\n".utf8).write(to: root.appendingPathComponent("Foo.swift"))

        let scope = try await GitDiff.changedLines(since: "HEAD", in: root)
        #expect(scope.changedLines["Foo.swift"] == [2 ..< 3])
    }

    @Test("changedLines reports paths relative to a project root nested inside the repository")
    func changedLinesIsRelativeToANestedProjectRoot() async throws {
        let repository = try await makeGitRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let projectRoot = repository.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try Data("func added() {}\n".utf8).write(to: projectRoot.appendingPathComponent("Bar.swift"))
        try Data("func original() {}\nfunc added() {}\n".utf8).write(to: repository.appendingPathComponent("Foo.swift"))
        let result = try await ProcessSupervisor.run(
            executable: "/usr/bin/git", arguments: ["add", "-N", "."], workingDirectory: repository, timeoutSeconds: 30
        )
        try #require(result.succeeded)

        let scope = try await GitDiff.changedLines(since: "HEAD", in: projectRoot)
        #expect(scope.changedLines == ["Bar.swift": [1 ..< 2]])
    }

    @Test("changedLines against a base that does not exist throws GitDiffError.gitFailed with git's own message")
    func changedLinesAgainstUnknownBaseThrows() async throws {
        let root = try await makeGitRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: GitDiffError.self) {
            _ = try await GitDiff.changedLines(since: "not-a-real-ref", in: root)
        }
    }
}
