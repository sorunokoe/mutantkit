import Foundation
import MutationExecution
import MutationModel
import Testing

/// `project.linkSiblings`: a monorepo whose `--project-root` is its iOS
/// directory can reference files one level out of it, e.g. a SwiftPM
/// `.binaryTarget(path: "../../shared/App.xcframework")`. A sandbox sits at a
/// different depth, so without these links that reference finds nothing and the
/// baseline build fails with no compiler diagnostic.
@Suite("WorkspaceManager: linkSiblings")
struct WorkspaceManagerLinkSiblingsTests {
    private let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-link-siblings-\(UUID().uuidString)")

    private var projectRoot: URL { repo.appendingPathComponent("iosApp") }
    private var scratchRoot: URL { projectRoot.appendingPathComponent(".mutantkit/sandboxes") }

    private func makeRepo() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: projectRoot.appendingPathComponent("Packages/Kit"), withIntermediateDirectories: true
        )
        try Data("// kit".utf8).write(to: projectRoot.appendingPathComponent("Packages/Kit/Kit.swift"))
        try fileManager.createDirectory(at: repo.appendingPathComponent("shared/build"), withIntermediateDirectories: true)
        try Data("framework".utf8).write(to: repo.appendingPathComponent("shared/build/App.xcframework"))
        try fileManager.createDirectory(at: repo.appendingPathComponent("android"), withIntermediateDirectories: true)
    }

    @Test("A sandbox resolves a reference that steps out of the project root to the real sibling")
    func sandboxResolvesSiblingReference() async throws {
        try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot, linkSiblings: ["shared"])
        let sandbox = try await workspaces.createSandbox(id: "baseline")

        let reference = sandbox.appendingPathComponent("Packages/Kit/../../../shared/build/App.xcframework")
        #expect(try String(contentsOf: reference, encoding: .utf8) == "framework")
    }

    @Test("Only the named siblings are linked")
    func onlyNamedSiblingsAreLinked() throws {
        try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        _ = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot, linkSiblings: ["shared"])

        let fileManager = FileManager.default
        #expect(try fileManager.destinationOfSymbolicLink(atPath: scratchRoot.appendingPathComponent("shared").path)
            == repo.appendingPathComponent("shared").path)
        #expect(!fileManager.fileExists(atPath: scratchRoot.appendingPathComponent("android").path))
    }

    @Test("No configured siblings links nothing")
    func defaultLinksNothing() throws {
        try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        _ = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)

        #expect(!FileManager.default.fileExists(atPath: scratchRoot.appendingPathComponent("shared").path))
    }

    @Test("A second run re-creates the link instead of failing on the existing one")
    func linkingIsRepeatable() throws {
        try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        _ = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot, linkSiblings: ["shared"])
        _ = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot, linkSiblings: ["shared"])

        let link = scratchRoot.appendingPathComponent("shared/build/App.xcframework")
        #expect(try String(contentsOf: link, encoding: .utf8) == "framework")
    }

    @Test("A real directory already in the scratch root is never replaced")
    func realDirectoryIsLeftAlone() throws {
        try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let existing = scratchRoot.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("marker"))

        _ = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot, linkSiblings: ["shared"])

        #expect(try String(contentsOf: existing.appendingPathComponent("marker"), encoding: .utf8) == "keep")
    }
}

@Suite("Configuration validation: project.linkSiblings")
struct ConfigurationLinkSiblingsValidationTests {
    private func issues(_ names: [String]) -> [ConfigurationIssue] {
        var configuration = Configuration()
        configuration.project.linkSiblings = names
        return ConfigurationValidator.validate(configuration).filter { $0.path == "project.linkSiblings" }
    }

    @Test("Plain sibling names are accepted")
    func plainNamesAreValid() {
        #expect(issues(["shared", "Vendor"]).isEmpty)
    }

    @Test("Paths, hidden names and empty names are rejected", arguments: ["", "../shared", "shared/build", ".git", ".."])
    func invalidNamesAreRejected(name: String) {
        #expect(issues([name]).count == 1)
    }
}
