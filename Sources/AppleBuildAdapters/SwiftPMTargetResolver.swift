import Foundation
import MutationExecution
import MutationModel
import MutationPlanner

/// Resolves which SwiftPM target/module/product each source file belongs
/// to — the `targetInfo` input `SchemataChunkPlanner.plan(...)` needs to
/// group mutations into chunks, and which no production code computed
/// before this: every existing caller of `SchemataChunkPlanner.plan`
/// (tests) hand-constructs it for a single, known fixture target.
///
/// Backed by `swift package describe --type json` rather than a hand-rolled
/// `Package.swift` parser: SwiftPM's own describe output is the same
/// target/source resolution `swift build` itself uses, including `path:`
/// overrides and non-default layouts a naive directory-convention guess
/// would get wrong.
public enum SwiftPMTargetResolver {
    public enum ResolutionError: Error, CustomStringConvertible {
        case describeFailed(diagnosis: String)
        case malformedOutput(String)

        public var description: String {
            switch self {
            case let .describeFailed(diagnosis): "`swift package describe` failed: \(diagnosis)"
            case let .malformedOutput(detail): "`swift package describe --type json` produced unparseable output: \(detail)"
            }
        }
    }

    struct DescribeOutput: Decodable {
        struct Target: Decodable {
            let name: String
            /// Project-root-relative, e.g. `"Sources/MutationModel"`.
            let path: String
            /// Target-relative, e.g. `"CoreTypes.swift"`.
            let sources: [String]
            let productMemberships: [String]?
            /// `"test"`, `"library"`, `"executable"`, and similar — SwiftPM's
            /// own classification, not inferred from a naming convention.
            let type: String
            /// Direct target-name dependencies — `SwiftPMDependencyGraph`
            /// builds the transitive closure from this, never a guess about
            /// what a target "probably" links against.
            let targetDependencies: [String]?
        }

        struct Product: Decodable {
            let name: String
            let targets: [String]
        }

        let targets: [Target]
        let products: [Product]
    }

    private static func describe(projectRoot: URL, timeoutSeconds: Double) async throws -> DescribeOutput {
        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcrun,
                arguments: ["swift", "package", "describe", "--type", "json"],
                workingDirectory: projectRoot,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            throw ResolutionError.describeFailed(diagnosis: "\(error)")
        }
        guard result.succeeded else {
            throw ResolutionError.describeFailed(diagnosis: String(decoding: result.standardError, as: UTF8.self))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(DescribeOutput.self, from: result.standardOutput)
        } catch {
            throw ResolutionError.malformedOutput("\(error)")
        }
    }

    /// One entry per source file the manifest actually declares, keyed by
    /// project-root-relative path — the same convention `MutationPoint.file`
    /// and `SchemataChunk`/`SchemataPlanEntry` already use everywhere else.
    /// A file belonging to more than one target (a rare but real SwiftPM
    /// configuration) gets one `SchemataTargetInfo` entry per membership —
    /// `SchemataChunkPlanner` already understands and routes this case to
    /// isolated fallback (`multipleTargetsNotYetSupported`), it does not
    /// need to be resolved here.
    ///
    /// `pathPrefix` rebases those keys when the package is not itself the
    /// project root (`project.path: Foundation/Core` under an umbrella
    /// `--project-root`): SwiftPM reports `Sources/Core/X.swift`, while every
    /// `MutationPoint.file` is `Foundation/Core/Sources/Core/X.swift`.
    /// Without it no planned file ever matched a key, and every mutation
    /// silently fell back to isolated mode (`missingTargetInfo`).
    public static func resolveTargetInfo(
        projectRoot: URL, pathPrefix: String? = nil, timeoutSeconds: Double = 120
    ) async throws -> [String: [SchemataTargetInfo]] {
        let decoded = try await describe(projectRoot: projectRoot, timeoutSeconds: timeoutSeconds)
        return Self.targetInfo(from: decoded, projectRoot: projectRoot, pathPrefix: pathPrefix)
    }

    static func targetInfo(from decoded: DescribeOutput, projectRoot: URL, pathPrefix: String? = nil) -> [String: [SchemataTargetInfo]] {
        let projectIdentity = Self.projectIdentity(for: projectRoot)
        var targetInfo: [String: [SchemataTargetInfo]] = [:]
        for target in decoded.targets {
            let info = SchemataTargetInfo(
                projectIdentity: projectIdentity,
                target: target.name,
                module: target.name,
                product: target.productMemberships?.first ?? target.name
            )
            for source in target.sources {
                let packageRelative = target.path == "." ? source : "\(target.path)/\(source)"
                let relativePath = pathPrefix.map { "\($0)/\(packageRelative)" } ?? packageRelative
                targetInfo[relativePath, default: []].append(info)
            }
        }
        return targetInfo
    }

    /// The real dependency graph, target types, and product membership —
    /// what `SwiftPMCompilationUnitImageResolver` needs to prove which real
    /// built image a compilation unit's target ends up in, by graph
    /// reachability rather than by matching a discovered bundle's filename
    /// against a target name.
    public static func resolveDependencyGraph(projectRoot: URL, timeoutSeconds: Double = 120) async throws -> SwiftPMDependencyGraph {
        let decoded = try await describe(projectRoot: projectRoot, timeoutSeconds: timeoutSeconds)
        return Self.dependencyGraph(from: decoded, projectRoot: projectRoot)
    }

    static func dependencyGraph(from decoded: DescribeOutput, projectRoot: URL) -> SwiftPMDependencyGraph {
        let projectIdentity = Self.projectIdentity(for: projectRoot)
        var targets: [String: SwiftPMDependencyGraph.TargetInfo] = [:]
        for target in decoded.targets {
            targets[target.name] = SwiftPMDependencyGraph.TargetInfo(
                name: target.name, type: target.type, path: target.path,
                sources: target.sources, dependencies: Set(target.targetDependencies ?? [])
            )
        }
        var products: [String: Set<String>] = [:]
        for product in decoded.products {
            products[product.name] = Set(product.targets)
        }
        return SwiftPMDependencyGraph(projectIdentity: projectIdentity, targets: targets, products: products)
    }

    private static func projectIdentity(for projectRoot: URL) -> String {
        // A package can have more than one `Package.swift` build description
        // per se, but for the resolved project this run operates on, its
        // own manifest is the one, stable identity every target here shares
        // — matching `SchemataChunk.projectIdentity`'s role of telling apart
        // two different projects that happen to name a target identically.
        projectRoot.appendingPathComponent("Package.swift").path
    }
}

/// The real SwiftPM target dependency graph, target types, and product
/// membership for one project — resolved from `swift package describe`,
/// never inferred from a target's own display name.
public struct SwiftPMDependencyGraph: Sendable {
    public struct TargetInfo: Sendable {
        public let name: String
        public let type: String
        /// Project-root-relative, e.g. `"Sources/MutationModel"` or a real
        /// custom layout like `"ExampleLib/Services"` — SwiftPM's own
        /// resolved `path:`, not a `Sources/<name>` convention guess. See
        /// `sourceFiles(reachableFrom:)`'s own doc comment for why this
        /// matters.
        public let path: String
        /// Target-relative filenames, straight from `swift package
        /// describe`'s own `sources` list for this target — e.g.
        /// `"CoreTypes.swift"`. Kept alongside `path` so
        /// `sourceFiles(reachableFrom:)` can name the exact files SwiftPM
        /// compiles, not just the directory they live in: a target whose
        /// manifest lists an explicit `sources:` allow-list narrower than
        /// its own directory (a real, not hypothetical, layout — a target
        /// directory holding one file deliberately left out of the
        /// product) makes `path` alone over-include that file.
        public let sources: [String]
        public let dependencies: Set<String>
    }

    public let projectIdentity: String
    public let targets: [String: TargetInfo]
    public let products: [String: Set<String>]

    public func isTestTarget(_ name: String) -> Bool {
        targets[name]?.type == "test"
    }

    /// Every target whose dependency chain (direct or transitive) includes
    /// `target` — the set of things that would statically link `target`'s
    /// compiled code into their own build product.
    public func transitiveDependents(of target: String) -> Set<String> {
        var dependents: Set<String> = []
        for (name, info) in targets where reaches(info, target: target) {
            dependents.insert(name)
        }
        return dependents
    }

    /// The real, resolved source paths of every non-test target reachable
    /// (directly or transitively) from `testTargets` — what `init`/`setup`
    /// should actually write as `sources.include`, instead of assuming the
    /// `Sources/**` convention.
    ///
    /// Found necessary against a real, independent SwiftPM package whose
    /// library source lived at a custom path (`ExampleLib/Services`, not
    /// `Sources/<TargetName>`): a hardcoded `Sources/**` silently included
    /// only the one unrelated file that happened to live under `Sources/`
    /// (an untested CLI's `main.swift`) and excluded all 35 real files the
    /// project's actual test target covered — worse than a zero-discovery
    /// warning, since `plan` still found a plausible-looking non-zero
    /// mutation count and nothing caught the mismatch.
    ///
    /// Named per file, not per target directory (`sourceFiles`, not
    /// `sourcePaths`): `Package.swift` can give a target an explicit
    /// `sources:` allow-list narrower than its own directory — a file
    /// physically present under that directory but never listed there is
    /// never compiled into any build product. A directory-level answer
    /// would still hand that file to `plan` as part of one glob, `mutantkit`
    /// would still discover mutations in it, and every one of those mutants
    /// would fail identically with `buildProductIdenticalToBaseline` — the
    /// build genuinely never changes, because the mutated file was never
    /// part of it. This is `plan`'s own live source of truth for a SwiftPM
    /// project's real, resolved compilation scope
    /// (`SwiftPMLiveSourceResolution`, `Sources/CLI`) — queried fresh on
    /// every `plan`, the same way Stryker.NET treats an MSBuild project's own
    /// `Compile` item list as authoritative rather than asking a separately
    /// maintained config file to duplicate it, rather than being snapshotted
    /// once into `mutantkit.yml` and left to drift from `Package.swift`.
    ///
    /// Deliberately test targets' own files are never included here — a
    /// test target's own source is not production code to mutate, and
    /// excluding it this way, by construction, is simpler and more direct
    /// than relying on `SourceSettings.defaultExcludes`' own glob patterns
    /// to happen to rule it out.
    public func sourceFiles(reachableFrom testTargets: [String]) -> [String] {
        var visited: Set<String> = []
        var files: [String] = []
        var queue = testTargets
        while let name = queue.popLast() {
            guard !visited.contains(name), let info = targets[name] else { continue }
            visited.insert(name)
            if info.type != "test" {
                // Only `.swift` files: a mixed-language target's `sources`
                // list can include `.c`/`.h`/`.m` siblings SwiftPM compiles
                // but `SourceFileWalker`/the mutation planner never can —
                // returning those here would write `sources.include`
                // entries that can never match anything the planner walks,
                // and would show up as spurious "under-included" noise on
                // every subsequent `plan`.
                files.append(contentsOf: info.sources
                    .filter { $0.hasSuffix(".swift") }
                    .map { Self.joinedSourcePath(targetPath: info.path, source: $0) })
            }
            queue.append(contentsOf: info.dependencies)
        }
        return files.sorted()
    }

    /// `swift package describe` reports a target rooted at the package root
    /// itself as `path: "."` — joining that naively (`"./Foo.swift"`) never
    /// matches `SourceFileWalker`'s own repository-relative output
    /// (`"Foo.swift"`, no leading `./`), which would make a freshly
    /// generated `sources.include` match nothing at all.
    private static func joinedSourcePath(targetPath: String, source: String) -> String {
        targetPath == "." ? source : "\(targetPath)/\(source)"
    }

    private func reaches(_ info: TargetInfo, target: String, visited: Set<String> = []) -> Bool {
        if info.dependencies.contains(target) { return true }
        var visited = visited
        visited.insert(info.name)
        for dependencyName in info.dependencies where !visited.contains(dependencyName) {
            guard let dependencyInfo = targets[dependencyName] else { continue }
            if reaches(dependencyInfo, target: target, visited: visited) { return true }
        }
        return false
    }

    public func buildTarget(named name: String) -> BuildTargetIdentity {
        BuildTargetIdentity(projectIdentity: projectIdentity, targetName: name, moduleName: name)
    }
}
