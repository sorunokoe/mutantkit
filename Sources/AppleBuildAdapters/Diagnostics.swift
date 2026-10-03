import Foundation
import MutationExecution
import MutationModel

/// The checks behind `mutantkit doctor`.
///
/// Each check runs the real command rather than inspecting a proxy for it, and
/// reports what it found. The point is to fail here, in seconds, with a remedy —
/// instead of two hours into a run where the same problem surfaces as a directory
/// of mutants that all mysteriously "did not compile".
enum Diagnostics {
    /// Every check for an xcodebuild-driven project, in the order a user reads them.
    static func full(adapter: XcodeBuildAdapter) async -> BuildDiagnosis {
        let workspace = workspace(for: adapter)
        var items: [DiagnosisItem] = []

        items.append(await xcodeVersion(workingDirectory: workspace))
        items.append(await swiftVersion(workingDirectory: workspace))
        items.append(contentsOf: await projectKind(workspace: workspace))

        // Scheme resolution gates everything after it: without a scheme there is
        // nothing to ask about targets, destinations or builds.
        let schemes = await adapter.discoverSchemes(in: workspace)
        items.append(schemeItem(schemes: schemes, configured: adapter.configuration.project.scheme))

        items.append(await destinations(adapter: adapter, workspace: workspace, schemes: schemes))
        items.append(derivedData(adapter: adapter, workspace: workspace))
        items.append(diskSpace(at: workspace))

        // The only check that proves the toolchain can actually produce something
        // testable. Run last because it is the slow one.
        items.append(contentsOf: await buildForTesting(adapter: adapter, workspace: workspace))

        return BuildDiagnosis(items: items)
    }

    /// Where every doctor check runs: the `--project-root`, never the current
    /// directory. CI usually starts `mutantkit` from the repository root, where
    /// there is no workspace, so a cwd-relative check failed `build-for-testing`
    /// with xcodebuild's bare exit 66. `projectFileRelativePath` is relative to
    /// this same root, so the build finds the workspace it was resolved against.
    static func workspace(for adapter: XcodeBuildAdapter) -> URL {
        adapter.projectRoot
    }

    // MARK: - Toolchain

    static func xcodeVersion(workingDirectory: URL) async -> DiagnosisItem {
        guard let result = try? await ProcessSupervisor.run(
            executable: ToolPaths.xcodebuild,
            arguments: ["-version"],
            workingDirectory: workingDirectory,
            timeoutSeconds: 60
        ), result.succeeded else {
            return DiagnosisItem(
                name: "Xcode",
                status: .failure,
                code: .xcodeToolchain,
                detail: "xcodebuild -version failed.",
                remedy: """
                Install Xcode and select it with `sudo xcode-select -s \
                /Applications/Xcode.app`.
                """
            )
        }

        let text = String(decoding: result.standardOutput, as: UTF8.self)
            .split(separator: "\n").joined(separator: " · ")
        return DiagnosisItem(name: "Xcode", status: .ok, code: .xcodeToolchain, detail: text)
    }

    static func swiftVersion(workingDirectory: URL) async -> DiagnosisItem {
        guard let result = try? await ProcessSupervisor.run(
            executable: ToolPaths.xcrun,
            arguments: ["swift", "--version"],
            workingDirectory: workingDirectory,
            timeoutSeconds: 60
        ), result.succeeded else {
            return DiagnosisItem(
                name: "Swift toolchain",
                status: .failure,
                code: .swiftToolchain,
                detail: "swift --version failed.",
                remedy: "Check `xcode-select -p` points at a valid Xcode."
            )
        }

        let text = String(decoding: result.standardOutput, as: UTF8.self)
            .split(separator: "\n").first.map(String.init) ?? "unknown"
        return DiagnosisItem(name: "Swift toolchain", status: .ok, code: .swiftToolchain, detail: text)
    }

    // MARK: - Project

    static func projectKind(workspace: URL) async -> [DiagnosisItem] {
        do {
            let detection = try await ProjectDetector.detect(in: workspace)
            return [DiagnosisItem(
                name: "Project kind",
                status: .ok,
                code: .projectDetected,
                detail: "\(detection.kind.rawValue) — \(detection.reason)"
            )]
        } catch {
            return [DiagnosisItem(
                name: "Project kind",
                status: .failure,
                code: .projectResolutionFailed,
                detail: "\(error)",
                remedy: """
                Run mutantkit from the directory holding your .xcworkspace, .xcodeproj \
                or Package.swift, or set project.path in mutantkit.yml.
                """
            )]
        }
    }

    private static func schemeItem(schemes: [String], configured: String?) -> DiagnosisItem {
        if let configured {
            // An empty list means discovery itself failed, which the build check
            // will report; only contradict the user when we actually know better.
            guard schemes.isEmpty || schemes.contains(configured) else {
                return DiagnosisItem(
                    name: "Schemes",
                    status: .failure,
                    code: .scheme,
                    detail: "mutantkit.yml asks for scheme '\(configured)', which does not exist. Available: \(schemes.joined(separator: ", ")).",
                    remedy: "Set project.scheme to one of the available schemes."
                )
            }
            return DiagnosisItem(
                name: "Schemes",
                status: .ok,
                code: .scheme,
                detail: "Using '\(configured)' from mutantkit.yml."
            )
        }

        switch schemes.count {
        case 0:
            return DiagnosisItem(
                name: "Schemes",
                status: .failure,
                code: .scheme,
                detail: "No schemes found.",
                remedy: """
                Mark a scheme shared in Xcode (Product > Scheme > Manage Schemes, \
                tick Shared), or set project.scheme in mutantkit.yml.
                """
            )
        case 1:
            return DiagnosisItem(name: "Schemes", status: .ok, code: .scheme, detail: "Using '\(schemes[0])'.")
        default:
            return DiagnosisItem(
                name: "Schemes",
                status: .warning,
                code: .scheme,
                detail: "\(schemes.count) schemes found: \(schemes.joined(separator: ", ")).",
                remedy: "Set project.scheme in mutantkit.yml; mutantkit will not pick one for you."
            )
        }
    }

    static func destinations(
        adapter: XcodeBuildAdapter,
        workspace: URL,
        schemes: [String]
    ) async -> DiagnosisItem {
        let requested = adapter.destination()
        guard let scheme = adapter.configuration.project.scheme ?? schemes.first else {
            return DiagnosisItem(
                name: "Destinations",
                status: .warning,
                code: .destination,
                detail: "Not checked: no scheme is resolved yet.",
                remedy: "Resolve the scheme problem above first."
            )
        }

        let result = try? await ProcessSupervisor.run(
            executable: ToolPaths.xcodebuild,
            arguments: ["-showdestinations", "-scheme", scheme],
            workingDirectory: workspace,
            timeoutSeconds: 180
        )

        guard let result, result.succeeded else {
            return DiagnosisItem(
                name: "Destinations",
                status: .warning,
                code: .destination,
                detail: "Could not list destinations for '\(scheme)'.",
                remedy: "Check the scheme builds in Xcode. Requested destination: \(requested)."
            )
        }

        let listed = parseDestinations(String(decoding: result.standardOutput, as: UTF8.self))
        guard !listed.isEmpty else {
            return DiagnosisItem(
                name: "Destinations",
                status: .failure,
                code: .destination,
                detail: "'\(scheme)' reports no available destinations.",
                remedy: """
                Install a simulator runtime in Xcode > Settings > Components, or point \
                project.destination at a device you have.
                """
            )
        }

        return DiagnosisItem(
            name: "Destinations",
            status: .ok,
            code: .destination,
            detail: "\(listed.count) available for '\(scheme)'; using \(requested). First: \(listed.prefix(3).joined(separator: " | "))."
        )
    }

    /// Pulls the readable part out of `-showdestinations` output.
    static func parseDestinations(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("{") && $0.contains("platform:") }
            .map { line in
                line.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("platform:") || $0.hasPrefix("name:") || $0.hasPrefix("OS:") }
                    .joined(separator: " ")
            }
    }

    static func derivedData(adapter: XcodeBuildAdapter, workspace: URL) -> DiagnosisItem {
        let path = adapter.derivedDataPath(in: workspace)

        // `ConfigurationValidator` rejects an absolute or `..`-escaping
        // `project.derivedDataPath` as an error, but `doctor` diagnoses the
        // environment even when the configuration failed that check (see
        // `ReadinessCheck.loadConfiguration`), so this can still be asked to
        // report on a path outside the sandbox. Only claim the isolation
        // guarantee when the resolved path is actually inside this workspace.
        //
        // Resolving symlinks (not just standardizing) on both sides — not
        // just `..` — before comparing catches a `project.derivedDataPath`
        // that names an ordinary-looking relative component which happens to
        // be a symlink pointing outside the workspace; a plain
        // `standardizedFileURL` collapses `..` but never follows a symlink,
        // so it would still call that path "inside" right up until
        // `xcodebuild` actually wrote through it. Comparing path COMPONENTS
        // rather than a raw string prefix avoids a security review's exact
        // finding on the first version of this check: plain `hasPrefix`
        // would wrongly call `/tmp/worker-10` "inside" `/tmp/worker-1`,
        // since one string is a textual prefix of the other despite being a
        // completely different, sibling directory.
        //
        // The comparison itself requires a STRICT descendant (`>`, not
        // `>=`): a `derivedDataPath` that resolves to the workspace root
        // itself is not "inside" it in any useful sense — DerivedData would
        // coexist with, and can overwrite, the sandbox's own source tree
        // rather than living in a dedicated subdirectory of it.
        let standardizedPath = resolvingSymlinksEvenIfMissing(path)
        let workspaceComponents = resolvingSymlinksEvenIfMissing(workspace).pathComponents
        let isInsideWorkspace = standardizedPath.pathComponents.count > workspaceComponents.count
            && Array(standardizedPath.pathComponents.prefix(workspaceComponents.count)) == workspaceComponents
        guard isInsideWorkspace else {
            return DiagnosisItem(
                name: "DerivedData",
                status: .warning,
                code: .derivedData,
                detail: "\(standardizedPath.path) resolves outside this workspace, so every concurrent "
                    + "worker would share it and could overwrite each other's build products.",
                remedy: "Set project.derivedDataPath to a relative path in mutantkit.yml."
            )
        }
        return DiagnosisItem(
            name: "DerivedData",
            status: .ok,
            code: .derivedData,
            detail: "\(path.path) (per-workspace, so concurrent mutants cannot overwrite each other's products)."
        )
    }

    static func diskSpace(at url: URL) -> DiagnosisItem {
        guard let free = availableDiskSpace(at: url) else {
            return DiagnosisItem(
                name: "Disk space",
                status: .warning,
                code: .diskSpace,
                detail: "Could not determine free space on the volume holding \(url.path)."
            )
        }

        // Each concurrent mutant carries its own copy of the sources and its own
        // DerivedData, so a mutation run needs far more headroom than one build.
        let gigabyte: Int64 = 1_073_741_824
        if free < 5 * gigabyte {
            return DiagnosisItem(
                name: "Disk space",
                status: .failure,
                code: .diskSpace,
                detail: "\(formatBytes(free)) free.",
                remedy: """
                Free at least 5 GB. Every worker keeps its own copy of the project and \
                its own DerivedData, and a full disk fails builds in ways that look \
                like compilation errors.
                """
            )
        }
        if free < 20 * gigabyte {
            return DiagnosisItem(
                name: "Disk space",
                status: .warning,
                code: .diskSpace,
                detail: "\(formatBytes(free)) free.",
                remedy: "Consider freeing space or lowering execution.workers."
            )
        }
        return DiagnosisItem(name: "Disk space", status: .ok, code: .diskSpace, detail: "\(formatBytes(free)) free.")
    }
}

/// The real build-for-testing check and everything it reads back out of the
/// result — split into its own extension purely to keep `Diagnostics`' own
/// body under this project's `type_body_length` limit (adding `DiagnosisItem
/// .Code` to every check pushed the single-enum-body version over it); this
/// is code motion only, not a behavior change.
extension Diagnostics {
    // MARK: - The real thing

    /// Actually builds, then checks the handoff artifact exists.
    static func buildForTesting(adapter: XcodeBuildAdapter, workspace: URL) async -> [DiagnosisItem] {
        do {
            let artifact = try await adapter.buildBaseline(in: workspace)

            var items = [DiagnosisItem(
                name: "build-for-testing",
                status: .ok,
                code: .trialBuild,
                detail: "Succeeded in \(String(format: "%.1f", artifact.command.durationSeconds ?? 0))s."
            )]

            if let xctestrun = artifact.xctestrunPath {
                items.append(DiagnosisItem(
                    name: ".xctestrun",
                    status: .ok,
                    code: .xctestrunArtifact,
                    detail: "Found \(xctestrun.lastPathComponent) by searching Build/Products."
                ))
                items.append(testTargets(inXCTestRun: xctestrun))
            } else {
                items.append(DiagnosisItem(
                    name: ".xctestrun",
                    status: .failure,
                    code: .xctestrunArtifact,
                    detail: "The build produced no .xctestrun.",
                    remedy: "Add a test target to the scheme's Test action."
                ))
            }

            items.append(productHash(artifact: artifact))
            return items
        } catch let failure as BuildFailure {
            return [DiagnosisItem(
                name: "build-for-testing",
                status: .failure,
                code: .trialBuild,
                detail: failure.diagnosis,
                remedy: failure.kind == .compilationError
                    ? "Fix the build first: mutation testing needs a project that compiles as-is."
                    : "Resolve the environment problem above, then run doctor again."
            )]
        } catch {
            return [DiagnosisItem(
                name: "build-for-testing",
                status: .failure,
                code: .trialBuild,
                detail: "\(error)",
                remedy: "Run the same xcodebuild command by hand to see the full output."
            )]
        }
    }

    /// Reads test target names out of the `.xctestrun` plist. `nil` means
    /// the plist itself could not be read (missing, unreadable, not a
    /// plist) — distinct from `[]`, a plist that read fine but named no
    /// test targets. `SetupCommand` (see its own `testTargets(inXCTestRun:)`
    /// wiring) reuses this exact parse to fall back to `.xctestrun`-based
    /// discovery when the static `.xcscheme` parse `XcodeConfigDetector
    /// .testTargets(forScheme:)` finds nothing — a real, post-build source
    /// that doesn't depend on a scheme file existing at all, unlike the
    /// static parse.
    static func testTargetNames(inXCTestRun url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any]
        else { return nil }

        // Format version 2 nests the targets under TestConfigurations; version 1
        // puts them at the top level next to a metadata key.
        if let configurations = root["TestConfigurations"] as? [[String: Any]] {
            var names: [String] = []
            for configuration in configurations {
                guard let targets = configuration["TestTargets"] as? [[String: Any]] else { continue }
                names.append(contentsOf: targets.compactMap { $0["BlueprintName"] as? String })
            }
            return names
        }
        return root.keys.filter { $0 != "__xctestrun_metadata__" }.sorted()
    }

    /// Reads test target names out of the `.xctestrun` plist.
    static func testTargets(inXCTestRun url: URL) -> DiagnosisItem {
        guard let names = testTargetNames(inXCTestRun: url) else {
            return DiagnosisItem(
                name: "Test targets",
                status: .warning,
                code: .testTargets,
                detail: "Could not read \(url.lastPathComponent).",
                remedy: "The file exists but is not a readable plist; try a clean build."
            )
        }

        guard !names.isEmpty else {
            return DiagnosisItem(
                name: "Test targets",
                status: .failure,
                code: .testTargets,
                detail: "\(url.lastPathComponent) lists no test targets.",
                remedy: "Enable a test target in the scheme's Test action."
            )
        }

        return DiagnosisItem(
            name: "Test targets",
            status: .ok,
            code: .testTargets,
            detail: names.sorted().joined(separator: ", ")
        )
    }

    static func productHash(artifact: BuildArtifact) -> DiagnosisItem {
        guard artifact.productHash != nil else {
            return DiagnosisItem(
                name: "Product hash",
                status: .warning,
                code: .productHash,
                detail: "No test binary was found under \(artifact.productsDirectory.path).",
                remedy: """
                Without this hash mutantkit cannot prove a mutant reached the binary, and \
                every mutant will be reported as unproven.
                """
            )
        }
        return DiagnosisItem(
            name: "Product hash",
            status: .ok,
            code: .productHash,
            detail: "Test binaries hashed; mutant activation can be proven."
        )
    }
}

/// `URL.resolvingSymlinksInPath()` only resolves the parts of a path that
/// actually exist on disk: it resolves a symlink itself just fine, but a
/// trailing component that does not exist yet (e.g. `ExternalDD/build`
/// before `xcodebuild` has created `build`) leaves the whole path
/// unresolved, symlink included — verified against a real symlink. That is
/// exactly the state `derivedDataPath` is normally in before a run starts,
/// so trusting `resolvingSymlinksInPath()` alone would report a
/// symlink-escaping path as safe right up until something else had already
/// created the directory. This resolves symlinks in the longest ancestor
/// that does exist, then reattaches whatever does not. Mirrors
/// `ConfigurationValidator`'s identical helper — kept local rather than
/// shared because `MutationModel` (where that one lives) does not, and
/// should not, depend on `AppleBuildAdapters`.
private func resolvingSymlinksEvenIfMissing(_ url: URL) -> URL {
    let fileManager = FileManager.default
    var existingAncestor = url.standardizedFileURL
    var missingSuffix: [String] = []
    while !fileManager.fileExists(atPath: existingAncestor.path), existingAncestor.pathComponents.count > 1 {
        missingSuffix.append(existingAncestor.lastPathComponent)
        existingAncestor = existingAncestor.deletingLastPathComponent()
    }
    return missingSuffix.reversed().reduce(existingAncestor.resolvingSymlinksInPath()) {
        $0.appendingPathComponent($1)
    }.standardizedFileURL
}
