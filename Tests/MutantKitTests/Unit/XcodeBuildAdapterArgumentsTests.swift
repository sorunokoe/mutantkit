@testable import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// `-only-testing:` is what keeps `tests.targets` meaningful for an
/// xcodebuild-based project. Found missing by actually running MutantKit against
/// a real app whose scheme built both a unit test target and a UI test
/// target: `tests.targets: [AppTests]` was silently ignored, the UI test
/// target ran anyway, and one of its tests failed the baseline for reasons
/// that had nothing to do with any mutation. This suite pins the argument
/// construction directly so a regression here does not need a real
/// toolchain and a flaky UI test to surface again.
@Suite("Xcode build adapter: test-without-building arguments")
struct XcodeBuildAdapterArgumentsTests {
    @Test("No configured targets means no -only-testing filter")
    func noTargetsMeansUnfiltered() {
        let arguments = XcodeBuildAdapter.testWithoutBuildingArguments(
            xctestrunPath: "/w/App.xctestrun",
            destination: "platform=iOS Simulator,name=iPhone 17",
            resultBundlePath: "/w/results/baseline.xcresult",
            targets: [],
            extraArguments: []
        )

        #expect(!arguments.contains { $0.hasPrefix("-only-testing:") })
    }

    @Test("Each configured target becomes its own -only-testing flag")
    func targetsBecomeOnlyTestingFlags() {
        let arguments = XcodeBuildAdapter.testWithoutBuildingArguments(
            xctestrunPath: "/w/App.xctestrun",
            destination: "platform=iOS Simulator,name=iPhone 17",
            resultBundlePath: "/w/results/baseline.xcresult",
            targets: ["AppTests"],
            extraArguments: []
        )

        #expect(arguments.contains("-only-testing:AppTests"))
        // The UI test target is exactly what must not run when it was not asked
        // for — this is the omission the real run against a real-world project surfaced.
        #expect(!arguments.contains("-only-testing:AppUITests"))
    }

    @Test("Multiple targets each get their own flag, in order")
    func multipleTargetsEachGetAFlag() {
        let arguments = XcodeBuildAdapter.testWithoutBuildingArguments(
            xctestrunPath: "/w/App.xctestrun",
            destination: "platform=iOS Simulator,name=iPhone 17",
            resultBundlePath: "/w/results/baseline.xcresult",
            targets: ["AppTests", "AppIntegrationTests"],
            extraArguments: []
        )

        #expect(arguments.contains("-only-testing:AppTests"))
        #expect(arguments.contains("-only-testing:AppIntegrationTests"))
    }

    @Test("Extra arguments still land after the target filters")
    func extraArgumentsAppendAfterFilters() {
        let arguments = XcodeBuildAdapter.testWithoutBuildingArguments(
            xctestrunPath: "/w/App.xctestrun",
            destination: "platform=iOS Simulator,name=iPhone 17",
            resultBundlePath: "/w/results/baseline.xcresult",
            targets: ["AppTests"],
            extraArguments: ["-quiet"]
        )

        #expect(arguments.contains("-only-testing:AppTests"))
        #expect(arguments.contains("-quiet"))
        #expect(arguments.firstIndex(of: "-only-testing:AppTests")! < arguments.firstIndex(of: "-quiet")!)
    }

    /// Found on a real project (the Debug Dylib fixture): xcodebuild's default
    /// (`on-failure`) runs a `simctl diagnose` sysdiagnose collection — its own
    /// timeout in the hundreds of seconds — the moment any mutant's first test
    /// fails, which half of them do by design. That collection can still be
    /// running when mutantkit's own, much shorter timeout fires and kills the
    /// process mid-write to the result bundle a wrong verdict then gets read
    /// from. MutantKit classifies from the structured result and the build
    /// product hash; it never reads a sysdiagnose.
    @Test("Test diagnostic collection is always disabled")
    func diagnosticCollectionIsDisabled() {
        let arguments = XcodeBuildAdapter.testWithoutBuildingArguments(
            xctestrunPath: "/w/App.xctestrun",
            destination: "platform=iOS Simulator,name=iPhone 17",
            resultBundlePath: "/w/results/baseline.xcresult",
            targets: ["AppTests"],
            extraArguments: []
        )

        #expect(arguments.contains("-collect-test-diagnostics"))
        let flagIndex = arguments.firstIndex(of: "-collect-test-diagnostics")!
        #expect(arguments[arguments.index(after: flagIndex)] == "never")
    }

    @Test("The fixed flags carry their exact values through")
    func fixedFlagsCarryThroughUnchanged() {
        let arguments = XcodeBuildAdapter.testWithoutBuildingArguments(
            xctestrunPath: "/w/App.xctestrun",
            destination: "platform=iOS Simulator,name=iPhone 17",
            resultBundlePath: "/w/results/baseline.xcresult",
            targets: [],
            extraArguments: []
        )

        #expect(arguments == [
            "test-without-building",
            "-xctestrun", "/w/App.xctestrun",
            "-destination", "platform=iOS Simulator,name=iPhone 17",
            "-resultBundlePath", "/w/results/baseline.xcresult",
            "-collect-test-diagnostics", "never"
        ])
    }
}

/// `ConfigurationValidator` rejects an absolute `project.derivedDataPath`
/// before a run starts (see `ConfigurationValidationTests`), so
/// `derivedDataPath(in:)` should never actually be asked to resolve one in
/// normal operation. These tests pin its fallback behavior anyway: the
/// adapter can be constructed directly (as it is here) without going through
/// that validation step, so the `hasPrefix("/")` handling is kept as a
/// defensive second line of isolation, not deleted just because validation
/// now covers the common path.
@Suite("Xcode build adapter: derivedDataPath resolution")
struct XcodeBuildAdapterDerivedDataPathTests {
    private static let workspace = URL(fileURLWithPath: "/tmp/mutantkit-worker-1")

    private func adapter(derivedDataPath: String?) -> XcodeBuildAdapter {
        var configuration = Configuration()
        configuration.project.derivedDataPath = derivedDataPath
        return XcodeBuildAdapter(
            configuration: configuration,
            kind: .xcodeProject,
            projectFile: nil,
            projectRoot: Self.workspace
        )
    }

    @Test("No configured path resolves under the workspace's own .mutantkit directory")
    func defaultsUnderWorkspace() {
        let path = adapter(derivedDataPath: nil).derivedDataPath(in: Self.workspace)
        #expect(path.path == Self.workspace.appendingPathComponent(".mutantkit/DerivedData").path)
    }

    @Test("A relative configured path resolves against the workspace")
    func relativePathResolvesAgainstWorkspace() {
        let path = adapter(derivedDataPath: "Build/DD").derivedDataPath(in: Self.workspace)
        #expect(path.path == Self.workspace.appendingPathComponent("Build/DD").path)
    }

    @Test("An absolute configured path is still returned unchanged, as a defensive fallback")
    func absolutePathFallsBackToItself() {
        let path = adapter(derivedDataPath: "/tmp/SharedDerivedData").derivedDataPath(in: Self.workspace)
        #expect(path.path == "/tmp/SharedDerivedData")
    }
}

/// `mutantkit doctor` diagnoses the environment even when configuration
/// validation already flagged an error (see `ReadinessCheck.loadConfiguration`),
/// so `Diagnostics.derivedData` can still be asked to report on an absolute,
/// out-of-sandbox path despite `ConfigurationValidator` rejecting one for a
/// real run. It must not claim the per-workspace isolation guarantee in that
/// case — see the false claim this replaces in the original bug report.
@Suite("Diagnostics: derivedData")
struct DiagnosticsDerivedDataTests {
    private static let workspace = URL(fileURLWithPath: "/tmp/mutantkit-worker-1")

    private func adapter(derivedDataPath: String?) -> XcodeBuildAdapter {
        var configuration = Configuration()
        configuration.project.derivedDataPath = derivedDataPath
        return XcodeBuildAdapter(
            configuration: configuration,
            kind: .xcodeProject,
            projectFile: nil,
            projectRoot: Self.workspace
        )
    }

    @Test("A path inside the workspace is reported as safe")
    func pathInsideWorkspaceIsOk() {
        let item = Diagnostics.derivedData(adapter: adapter(derivedDataPath: nil), workspace: Self.workspace)
        #expect(item.status == .ok)
        #expect(item.detail.contains("per-workspace"))
    }

    @Test("An absolute path outside the workspace is reported as unsafe, not per-workspace")
    func absolutePathOutsideWorkspaceIsWarned() {
        let item = Diagnostics.derivedData(
            adapter: adapter(derivedDataPath: "/tmp/SharedDerivedData"),
            workspace: Self.workspace
        )
        #expect(item.status == .warning)
        #expect(!item.detail.contains("per-workspace, so concurrent mutants cannot overwrite"))
    }

    /// A security review of the first version of this check found a plain
    /// `hasPrefix` string comparison wrongly calls a sibling directory
    /// "inside" the workspace whenever one path string happens to be a
    /// textual prefix of the other — `/tmp/mutantkit-worker-1` is a prefix
    /// of `/tmp/mutantkit-worker-10`, but the second is a completely
    /// different worker's directory, not a subdirectory of the first.
    @Test("A sibling directory that shares a path-string prefix with the workspace is not mistaken for inside it")
    func siblingDirectoryWithSharedPrefixIsNotMistakenForInside() {
        let item = Diagnostics.derivedData(
            adapter: adapter(derivedDataPath: "/tmp/mutantkit-worker-10/DerivedData"),
            workspace: Self.workspace
        )
        #expect(item.status == .warning)
        #expect(!item.detail.contains("per-workspace, so concurrent mutants cannot overwrite"))
    }

    /// A `derivedDataPath` that resolves to the workspace root itself is not
    /// "inside" it in any useful sense: DerivedData would coexist with, and
    /// can overwrite, the sandbox's own source tree. The comparison this
    /// check makes must therefore require a strict descendant (`>`), not
    /// accept exact equality (`>=`) as "inside".
    @Test("A path that resolves to the workspace root itself is reported as unsafe, not per-workspace")
    func pathEqualToWorkspaceRootIsWarned() {
        let item = Diagnostics.derivedData(
            adapter: adapter(derivedDataPath: "."),
            workspace: Self.workspace
        )
        #expect(item.status == .warning)
        #expect(!item.detail.contains("per-workspace, so concurrent mutants cannot overwrite"))
    }

    /// A relative `derivedDataPath` naming a symlinked directory that
    /// resolves outside the workspace must be caught here too, as a
    /// defense-in-depth backstop alongside `ConfigurationValidator`'s own
    /// symlink check: `doctor` runs even when configuration validation
    /// already failed (see `ReadinessCheck.loadConfiguration`), so this is
    /// often the only check that actually ran against this exact workspace.
    @Test("A relative path that resolves outside the workspace through a symlink is reported as unsafe")
    func symlinkEscapingPathIsWarned() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-DiagnosticsDerivedDataTests-\(UUID().uuidString)")
        let outsideTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-DiagnosticsDerivedDataTests-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outsideTarget)
        }

        let symlink = workspace.appendingPathComponent("ExternalDD")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideTarget)

        let item = Diagnostics.derivedData(
            adapter: adapter(derivedDataPath: "ExternalDD/build"),
            workspace: workspace
        )
        #expect(item.status == .warning)
        #expect(!item.detail.contains("per-workspace, so concurrent mutants cannot overwrite"))
    }
}

/// Phase C10 (competitive-parity program): `destinationNeedsSimulatorLease`
/// used to check only `"iOS Simulator"`, so a tvOS/watchOS/visionOS
/// destination was silently treated as needing no mutual exclusion at all —
/// two concurrent workers could install and run tests on the very same real
/// simulator device with no lease protecting either from the other.
@Suite("Xcode build adapter: destinationNeedsSimulatorLease covers every simulator platform")
struct XcodeBuildAdapterSimulatorLeaseCoverageTests {
    private static let workspace = URL(fileURLWithPath: "/tmp/mutantkit-worker-1")

    private func adapter(destination: String) -> XcodeBuildAdapter {
        var configuration = Configuration()
        configuration.project.destination = destination
        return XcodeBuildAdapter(
            configuration: configuration,
            kind: .xcodeProject,
            projectFile: nil,
            projectRoot: Self.workspace
        )
    }

    @Test("An iOS Simulator destination needs a lease (unchanged behavior)")
    func iOSNeedsLease() {
        #expect(adapter(destination: "platform=iOS Simulator,name=iPhone 16").destinationNeedsSimulatorLease)
    }

    @Test("A tvOS Simulator destination needs a lease")
    func tvOSNeedsLease() {
        #expect(adapter(destination: "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)").destinationNeedsSimulatorLease)
    }

    @Test("A watchOS Simulator destination needs a lease")
    func watchOSNeedsLease() {
        #expect(adapter(destination: "platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)").destinationNeedsSimulatorLease)
    }

    @Test("A visionOS Simulator destination needs a lease")
    func visionOSNeedsLease() {
        #expect(adapter(destination: "platform=visionOS Simulator,name=Apple Vision Pro").destinationNeedsSimulatorLease)
    }

    @Test("A macOS destination needs no lease")
    func macOSNeedsNoLease() {
        #expect(!adapter(destination: "platform=macOS").destinationNeedsSimulatorLease)
    }

    @Test("A generic simulator placeholder needs no lease, for every simulator platform")
    func genericPlaceholderNeedsNoLease() {
        #expect(!adapter(destination: "generic/platform=iOS Simulator").destinationNeedsSimulatorLease)
        #expect(!adapter(destination: "generic/platform=tvOS Simulator").destinationNeedsSimulatorLease)
    }
}

/// CI starts `mutantkit doctor` from the repository root while `--project-root`
/// points at the app's subdirectory. Doctor used to run its xcodebuild checks in
/// the current directory, found no workspace there, and failed
/// `build-for-testing` with a bare exit 66.
@Suite("Diagnostics: workspace")
struct DiagnosticsWorkspaceTests {
    private static let projectRoot = URL(fileURLWithPath: "/tmp/repo/iosApp")

    private func adapter(projectPath: String?) -> XcodeBuildAdapter {
        var configuration = Configuration()
        configuration.project.path = projectPath
        return XcodeBuildAdapter(
            configuration: configuration,
            kind: .xcodeWorkspace,
            projectFile: Self.projectRoot.appendingPathComponent("App.xcworkspace"),
            projectRoot: Self.projectRoot
        )
    }

    @Test("Doctor checks run in the project root, not the current directory")
    func usesProjectRoot() {
        #expect(Diagnostics.workspace(for: adapter(projectPath: nil)) == Self.projectRoot)
    }

    @Test("A cwd-relative project.path does not move the checks away from the project root")
    func ignoresCwdRelativeProjectPath() {
        #expect(Diagnostics.workspace(for: adapter(projectPath: ".")) == Self.projectRoot)
    }

    @Test("The workspace file is found under the project root")
    func workspaceFileIsUnderProjectRoot() {
        let adapter = adapter(projectPath: nil)
        let workspace = Diagnostics.workspace(for: adapter)
        #expect(adapter.projectFileRelativePath == "App.xcworkspace")
        #expect(workspace.appendingPathComponent("App.xcworkspace").path == "/tmp/repo/iosApp/App.xcworkspace")
    }
}
