import Darwin
import Foundation
import MutationModel

/// Something went wrong creating, populating or destroying a sandbox.
public enum WorkspaceError: Error, CustomStringConvertible {
    case invalidSandboxID(String)
    case sandboxOutsideScratchRoot(path: String, scratchRoot: String)
    case pathOutsideSandbox(path: String, sandbox: String)
    case unreadable(path: String, underlying: String)
    case unwritable(path: String, underlying: String)

    public var description: String {
        switch self {
        case let .invalidSandboxID(id):
            "\(String(reflecting: id)) is not a usable sandbox name."
        case let .sandboxOutsideScratchRoot(path, scratchRoot):
            "Refusing to delete \(path): it resolves outside the scratch root \(scratchRoot)."
        case let .pathOutsideSandbox(path, sandbox):
            "Refusing to touch \(path): it resolves outside the sandbox \(sandbox)."
        case let .unreadable(path, underlying):
            "Could not read \(path): \(underlying)"
        case let .unwritable(path, underlying):
            "Could not write \(path): \(underlying)"
        }
    }
}

/// Creates and destroys the throwaway project copies that mutants are built in.
///
/// A mutation is a destructive edit to a source file, and the user's working tree
/// is never where one gets made: a run that is killed halfway through must not be
/// able to leave mutated code behind. Every mutant therefore gets its own copy of
/// the project under the tool's scratch root, and `WorkspaceManager` itself —
/// every method in this file — only ever reads `projectRoot`, never writes to it.
///
/// That is a narrower claim than "the original tree is only ever read by
/// this tool," which does not hold without qualification: with
/// `Configuration.execution.retestKilledMutants` on for a SwiftPM project,
/// `RunCommand`'s own dependency-resolution preflight
/// (`PackageManifestConfirmationRetesting
/// .resolveDependenciesForConfirmationRetest`) deliberately runs `swift
/// package resolve` against `projectRoot` once, up front, and logs doing
/// so — a real, intentional, narrowly-scoped exception to keep a later
/// confirmation retest from performing that same first-ever resolution
/// unexpectedly, mid-run, instead (see that method's own doc comment for
/// why). `WorkspaceManager` has no part in that and remains read-only.
///
/// Copies are made with `clonefile(2)` where the filesystem allows it. On APFS
/// that is copy-on-write, so a sandbox costs directory entries rather than a
/// duplicate of the tree, which is what makes one-sandbox-per-mutant affordable
/// at all.
///
/// `git worktree` would be the obvious alternative and is deliberately not used:
/// it materializes committed state, so it would silently test something other
/// than the code the user is looking at.
public actor WorkspaceManager {
    private let projectRoot: URL
    /// Canonical (symlink-resolved). Every deletion is checked against this.
    private let scratchRoot: URL
    private let excludes: [String]
    private let fileManager = FileManager.default
    private var cloneSupport: Bool?
    /// See `ExecutionSettings.cleanSubtreeCloning`'s doc comment for what
    /// this turns on and why it defaults off.
    private let cleanSubtreeCloning: Bool
    /// Built lazily, on the first `createSandbox` that needs it, and cached
    /// for the rest of this instance's lifetime -- see
    /// `cachedCleanSubtreeIndex()`.
    private var cleanSubtreeIndex: CleanSubtreeIndex?

    /// Directories that hold build output, VCS state or previous runs. Copying
    /// them is pure cost: the build regenerates them, and DerivedData alone can
    /// outweigh the source tree by an order of magnitude.
    ///
    /// Both tool-output roots are excluded: `.mutantkit` is current and
    /// `.mutare` is the prior tool name. A previous incident cloned a stale
    /// 15 GB `.mutare` into every sandbox because only the current name was
    /// listed here; keeping both prevents that from recurring for anyone whose
    /// tree still carries the old directory.
    public static let defaultExcludes = [
        ".git",
        ".build",
        "DerivedData",
        "Build",
        "Pods",
        "Carthage/Build",
        ".mutantkit",
        ".mutare",
        "*.xcresult",
        "*.log",
        "logs"
    ]

    public init(
        projectRoot: URL,
        scratchRoot: URL,
        excludes: [String] = WorkspaceManager.defaultExcludes,
        cleanSubtreeCloning: Bool = false,
        linkSiblings: [String] = []
    ) throws {
        self.projectRoot = projectRoot.standardizedFileURL
        self.excludes = excludes
        self.cleanSubtreeCloning = cleanSubtreeCloning

        // The scratch root must exist before it can be canonicalized: symlink
        // resolution only resolves the parts of a path that are really there,
        // and a half-resolved root would make the containment check below
        // compare two spellings of the same directory and reject them.
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        self.scratchRoot = scratchRoot.resolvingSymlinksInPath().standardizedFileURL

        // Best-effort, and unconditional: this runs whether or not the
        // caller ends up using `Configuration.execution.sharedModuleCache`
        // at all, so every process that ever constructs a `WorkspaceManager`
        // against a given scratch root -- `mutantkit run`, `reproduce`,
        // `dry-run`, `SchemataChunkBuildProbe` alike -- starts from a
        // provably empty shared module cache rather than one a previous
        // invocation (possibly under a different toolchain) left behind.
        // This is what keeps "the shared cache is stale from a prior run,
        // or was built by a compiler version that no longer matches"
        // outside this feature's own correctness surface entirely: there is
        // no cross-invocation reuse to reason about, because nothing is
        // *meant* to survive between invocations. "Best-effort" above is
        // literal, not decorative: `try?` swallows the removal's own error
        // rather than surfacing or logging it, so a failed wipe (permission
        // denied, a file busy from something else touching the same path)
        // is silently ignored, not merely unlikely. The directory is left
        // absent afterwards -- `-Xswiftc -module-cache-path` creates it
        // lazily on first use (confirmed empirically), so there is
        // nothing useful to recreate here.
        //
        // This wipe is also unconditional in a second sense worth flagging
        // here, not just at `sharedModuleCache`'s own doc comment: it is
        // keyed on `scratchRoot` alone, which is stable (`<projectRoot>/
        // .mutantkit`) rather than per-run, and it races a concurrent
        // `WorkspaceManager` construction against the *same* project from a
        // *different* destination's run -- see
        // `ExecutionSettings.sharedModuleCache`'s doc comment for the full
        // shape of that limitation.
        try? FileManager.default.removeItem(
            at: self.scratchRoot.appendingPathComponent(Self.moduleCacheDirectoryName, isDirectory: true)
        )

        Self.linkProjectRootSiblings(linkSiblings, of: self.projectRoot, into: self.scratchRoot)
    }

    /// Gives every sandbox the neighbours `project.linkSiblings` names.
    ///
    /// A sandbox sits at `<scratchRoot>/<name>`, standing in for the project
    /// root, so a relative reference that steps one level out of the root —
    /// e.g. a SwiftPM `.binaryTarget(path: "../../shared/App.xcframework")` in a
    /// monorepo where `--project-root` is the iOS directory — resolves against
    /// `scratchRoot` instead of the root's real parent, finds nothing, and fails
    /// the baseline build with no compiler diagnostic. A symlink in
    /// `scratchRoot` per named sibling makes those references resolve to the
    /// real files again. Sources are never mutated through these links: every
    /// planned file lives inside the project root, which is copied, not linked.
    ///
    /// Opt-in rather than every sibling: a project root's parent can be a whole
    /// directory of unrelated projects. Names are validated by
    /// `ConfigurationValidator`; an existing entry is replaced only if it is
    /// itself a link, so a sandbox directory is never touched.
    static func linkProjectRootSiblings(_ names: [String], of projectRoot: URL, into scratchRoot: URL) {
        let parent = projectRoot.deletingLastPathComponent()
        let fileManager = FileManager.default
        for name in names {
            let link = scratchRoot.appendingPathComponent(name)
            if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try? fileManager.removeItem(at: link)
            } else if fileManager.fileExists(atPath: link.path) {
                continue
            }
            try? fileManager.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: parent.appendingPathComponent(name).path
            )
        }
    }

    // MARK: - Lifecycle

    /// Directory name for a sandbox: a fixed-width digest of `id`.
    ///
    /// The width is the point, and it is load-bearing for correctness rather
    /// than tidiness. The absolute build path reaches the compiled output — as
    /// `#file` strings and as constants that `__TEXT,__text` addresses — so the
    /// *length* of a sandbox's path changes the emitted code even when the
    /// source is byte-identical. Measured on this toolchain: identical sources
    /// built at two equal-length paths produce identical code, and at
    /// different-length paths produce different code.
    ///
    /// Activation evidence compares a mutant's compiled code against the
    /// baseline's. If the baseline sat at `…/baseline` and mutants at
    /// `…/mut_<16 hex>`, that comparison would report "differs" for every mutant
    /// purely because the paths differ in length — including for mutants that
    /// changed nothing. The phantom check would never fire and every mutant
    /// would carry a false proof of activation, which is worse than carrying
    /// none.
    ///
    /// Hashing rather than padding keeps the invariant true for *any* caller and
    /// any id, instead of resting on callers happening to pick equal-length
    /// names. It is deterministic, so a sandbox for the same id is always at the
    /// same path and `reproduce` stays reproducible.
    /// Public because the equal-length guarantee is part of this type's contract,
    /// not an implementation detail: activation evidence depends on it, so it is
    /// something callers may assert against.
    public static func directoryName(for id: String) -> String {
        "sbx_" + ContentHash.shortDigest(of: id, length: 20)
    }

    /// Fixed name for the shared, run-scoped Clang/Swift module cache
    /// directory every sandbox under one scratch root may point its build
    /// at -- see `Configuration.execution.sharedModuleCache`. A literal
    /// constant, not a hashed digest like `directoryName(for:)` above: there
    /// is at most one of these per scratch root, so nothing about it needs
    /// to be unique or unguessable, and a stable, greppable name makes it
    /// easy to find on disk while debugging. Dot-prefixed so it reads
    /// unmistakably as this manager's own infrastructure, never mistaken
    /// for a mutant sandbox (`sbx_...`) or a products clone (`prd_...`).
    public static let moduleCacheDirectoryName = ".module-cache"

    /// `moduleCacheDirectoryName` above, namespaced by a real toolchain
    /// fingerprint (see `SharedModuleCacheFingerprint`) -- the real,
    /// on-disk directory name `moduleCachePath(forSandbox:fingerprint:)`
    /// resolves to. A second, independent layer of protection on top of
    /// `init`'s own wipe-at-construction of the plain, unnamespaced
    /// directory above: that wipe is `try?`-guarded best-effort and only
    /// ever runs once, so it cannot by itself guarantee a toolchain change
    /// (mid-session, or between two invocations that reuse a path) can
    /// never collide with an old cache's own contents -- namespacing by
    /// fingerprint makes that guarantee structural instead. The plain
    /// directory name is still wiped, unchanged, purely for backward-
    /// compatible cleanup of a cache directory an older, pre-fingerprint
    /// version of this tool may have left behind; nothing writes there
    /// going forward.
    ///
    /// `fingerprint` is a short digest a caller already computed (see
    /// `SharedModuleCacheFingerprint.digest`), never re-derived here: this
    /// function does no probing of its own and stays exactly as easy to
    /// call from a pure, synchronous, sandbox-path-only context as
    /// `directoryName(for:)`/`productsCloneDirectoryName(for:)` above.
    public static func moduleCacheDirectoryName(forFingerprint fingerprint: String) -> String {
        ".module-cache-" + fingerprint
    }

    /// Where the fingerprint-namespaced shared module cache lives for a
    /// sandbox this manager created -- one path component up from the
    /// sandbox itself, i.e. directly under this manager's own
    /// `scratchRoot`.
    ///
    /// A `BuildAdapter` never sees `scratchRoot` directly, only the sandbox
    /// URL it is asked to build in -- this lets it recover the shared
    /// cache's location anyway, without threading a second path through
    /// every adapter-construction call site. Safe because `createSandbox`'s
    /// own contract (see its doc comment) guarantees every sandbox this
    /// type ever hands out is exactly one path component below its scratch
    /// root, always -- so `sandbox`'s parent directory *is* that scratch
    /// root, whichever `WorkspaceManager` produced it.
    public nonisolated static func moduleCachePath(forSandbox sandbox: URL, fingerprint: String) -> URL {
        moduleCachePath(underScratchRoot: sandbox.deletingLastPathComponent(), fingerprint: fingerprint)
    }

    /// The same path `moduleCachePath(forSandbox:fingerprint:)` resolves,
    /// expressed directly from a scratch root rather than from a sandbox
    /// inside it -- for a caller that has not created (and may never
    /// create) any sandbox, such as `mutantkit doctor`'s module-cache
    /// diagnostic previewing what a real `mutantkit run` would resolve to.
    public nonisolated static func moduleCachePath(underScratchRoot scratchRoot: URL, fingerprint: String) -> URL {
        scratchRoot.appendingPathComponent(moduleCacheDirectoryName(forFingerprint: fingerprint), isDirectory: true)
    }

    /// Builds a fresh sandbox for `id` and returns its canonical location.
    public func createSandbox(id: String) async throws -> URL {
        // `id` reaches us from a plan file, which is data we did not write. It is
        // hashed below rather than used as a path component, which already
        // neutralizes separators and `..` — but a malformed id is still a bug
        // worth reporting rather than quietly hashing into a valid-looking name.
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw WorkspaceError.invalidSandboxID(id)
        }

        let sandbox = scratchRoot
            .appendingPathComponent(Self.directoryName(for: id))
            .standardizedFileURL
        guard sandbox.path.hasPrefix(scratchRoot.path + "/") else {
            throw WorkspaceError.sandboxOutsideScratchRoot(path: sandbox.path, scratchRoot: scratchRoot.path)
        }

        do {
            try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceError.unwritable(path: sandbox.path, underlying: error.localizedDescription)
        }

        try populate(from: projectRoot, to: sandbox, relativePath: "")
        return sandbox
    }

    /// Deletes a sandbox, refusing anything that is not really inside the scratch root.
    ///
    /// This runs against a path that has been through a plan file, a build
    /// adapter and a filesystem, so it re-derives the answer instead of trusting
    /// it: the path is canonicalized first, which is what catches a sandbox that
    /// is a symlink to somewhere that matters. A recursive delete gets exactly
    /// one chance to be wrong.
    public func destroySandbox(at url: URL) async throws {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path != scratchRoot.path, canonical.path.hasPrefix(scratchRoot.path + "/") else {
            throw WorkspaceError.sandboxOutsideScratchRoot(path: canonical.path, scratchRoot: scratchRoot.path)
        }
        guard fileManager.fileExists(atPath: canonical.path) else { return }

        do {
            try fileManager.removeItem(at: canonical)
        } catch {
            throw WorkspaceError.unwritable(path: canonical.path, underlying: error.localizedDescription)
        }
    }

    /// Overwrites one file inside `sandbox` with the pristine copy from
    /// `projectRoot` — the revert half of a persistent, reused sandbox.
    ///
    /// Only for sandboxes meant to survive across multiple mutants (see
    /// `Configuration.execution.incrementalBuild`): a mutation is applied
    /// in place, built and tested, and this restores exactly the one file
    /// it touched before the next mutation is applied, so the sandbox is
    /// byte-identical to a fresh clone without paying to make a fresh one.
    /// The single-mutation-per-file invariant `MutationApplication` relies
    /// on means one file is always enough; nothing else in the sandbox is
    /// ever written to.
    public func restoreFile(relativePath: String, in sandbox: URL) async throws {
        let source = try resolveSourceURL(in: projectRoot, relativePath: relativePath)
        let destination = try resolveSourceURL(in: sandbox, relativePath: relativePath)
        try materialize(source, at: destination)
    }

    /// Directory name for a cloned build-products landing spot: the same
    /// fixed-width digest shape as `directoryName(for:)` (see its doc comment
    /// for why the width matters), but under its own prefix so it can never
    /// collide with a sandbox's own directory.
    public static func productsCloneDirectoryName(for id: String) -> String {
        "prd_" + ContentHash.shortDigest(of: id, length: 20)
    }

    /// Clones a just-built products directory out to its own, uniquely
    /// identified location, independent of the sandbox that built it.
    ///
    /// Only useful alongside a persistent, reused sandbox (see
    /// `Configuration.execution.incrementalBuild`): the whole point of
    /// reusing a sandbox is that its `DerivedData` gets overwritten in place
    /// by the very next mutant's build, which would corrupt this mutant's
    /// artifact if testing it is deferred (see `Configuration.execution
    /// .testBatchSize`). Cloning it out first lets the worker move on to its
    /// next mutant immediately, while this clone survives independently
    /// until it is tested and destroyed.
    ///
    /// `id` must be unique per artifact being kept alive — a mutation ID,
    /// never a worker ID: the worker's own sandbox path has to stay stable
    /// across mutants (that is what makes it incremental), while every
    /// clone must not. Same validation as `createSandbox`: `id` is data from
    /// a plan file, hashed rather than used as a path component.
    ///
    /// Clones the whole directory in one call rather than file-by-file:
    /// `clonefile(2)` recursively clones a directory hierarchy atomically,
    /// and nothing downstream of a build (`XCTestRunLocator`, a `.xctestrun`'s
    /// own `__TESTROOT__`-relative paths) ever looks outside this directory —
    /// see `XcodeBuildAdapter.productsDirectory(in:)` and `XCTestRunLocator`.
    public func cloneProducts(from productsDirectory: URL, id: String) async throws -> URL {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw WorkspaceError.invalidSandboxID(id)
        }

        let destination = scratchRoot
            .appendingPathComponent(Self.productsCloneDirectoryName(for: id))
            .standardizedFileURL
        guard destination.path.hasPrefix(scratchRoot.path + "/") else {
            throw WorkspaceError.sandboxOutsideScratchRoot(path: destination.path, scratchRoot: scratchRoot.path)
        }

        // `clone(_:to:)` below uses `CLONE_NOFOLLOW` so a symlink *inside* a
        // cloned tree is recreated as a symlink, never dereferenced into a
        // copy (see that function's own doc comment) — correct for
        // `populate`'s recursive walk, but wrong here: `productsDirectory`
        // itself, the top-level source, is routinely a symlink (SwiftPM's
        // own `.build/debug`, always a relative symlink to
        // `.build/<triple>/debug`). Cloning that top-level symlink with
        // `CLONE_NOFOLLOW` would recreate the same *relative* link text at
        // `destination` — pointing at `destination/../<triple>/debug`, which
        // does not exist, since only the products directory is cloned out,
        // never its siblings. Resolving here, once, before either the clone
        // or its existence check, makes `destination` a real, independent
        // directory whatever `productsDirectory` itself was.
        let resolvedProductsDirectory = productsDirectory.resolvingSymlinksInPath()

        guard fileManager.fileExists(atPath: resolvedProductsDirectory.path) else {
            throw WorkspaceError.unreadable(
                path: resolvedProductsDirectory.path,
                underlying: "no such directory"
            )
        }

        // clonefile refuses an existing destination — matches `materialize`'s
        // own removal-before-clone, needed here so re-cloning under a reused
        // `id` (a worker's next mutant landing on the same digest, once the
        // prior clone has already been destroyed) overwrites cleanly.
        try? fileManager.removeItem(at: destination)

        if supportsAPFSClone(), Self.clone(resolvedProductsDirectory, to: destination) {
            return destination
        }

        do {
            try fileManager.copyItem(at: resolvedProductsDirectory, to: destination)
        } catch {
            throw WorkspaceError.unwritable(path: destination.path, underlying: error.localizedDescription)
        }
        return destination
    }

    /// Clones a just-built products directory the same way `cloneProducts`
    /// does, but nested under `<destination>/<triple>/<configuration>/`
    /// instead of flattened directly into `destination` — the shape
    /// `SwiftPackageMacOSAdapter`'s confirmation retest needs `swift test
    /// --scratch-path` to find pre-built products under.
    ///
    /// A sibling function, not a parameter on `cloneProducts`: that
    /// function's flat shape is load-bearing for its other caller
    /// (`Configuration.execution.testBatchSize`'s batching path, both the
    /// plain and the pipelined-incremental variants — see `MutationRunner
    /// .relocating`) and for `XcodeBuildAdapter`'s own confirmation retest,
    /// whose `.xctestrun`'s `__TESTROOT__`-relative paths need the flat
    /// directory unchanged (see `cloneProducts`'s own doc comment). Nesting
    /// it for every caller would break both; this function exists so only
    /// the one caller that actually needs the nested shape
    /// (`MutationConfirmationCoordinator.confirmKill`, for an adapter that
    /// conforms to `PackageManifestConfirmationRetesting`) pays for it.
    ///
    /// Confirmed empirically against a real toolchain: `swift test
    /// --scratch-path X` does not accept a flat products directory at
    /// all — it computes its own triple/configuration path internally
    /// and looks for pre-built products at exactly
    /// `X/<triple>/<configuration>/`, failing with a `dlopen` "no such
    /// file" if that nesting is not there, regardless of what `X`
    /// itself otherwise contains.
    ///
    /// `<triple>` and `<configuration>` are read off `productsDirectory`'s
    /// own resolved path — the same value SwiftPM itself already computed
    /// when it built these products (its `.build/debug` symlink resolves to
    /// exactly `.build/<triple>/<configuration>`) — never hardcoded, so this
    /// stays correct across architectures, cross-compilation destinations,
    /// and a non-`debug` configuration alike, with no toolchain-version- or
    /// host-specific guessing.
    public func cloneProductsForConfirmation(from productsDirectory: URL, id: String) async throws -> URL {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw WorkspaceError.invalidSandboxID(id)
        }

        let destination = scratchRoot
            .appendingPathComponent(Self.productsCloneDirectoryName(for: id))
            .standardizedFileURL
        guard destination.path.hasPrefix(scratchRoot.path + "/") else {
            throw WorkspaceError.sandboxOutsideScratchRoot(path: destination.path, scratchRoot: scratchRoot.path)
        }

        // Resolved for the same reason `cloneProducts` resolves it — see
        // that function's own doc comment: `productsDirectory` itself is
        // routinely a relative symlink (SwiftPM's own `.build/debug`), and
        // this is also where `<triple>`/`<configuration>` are read from, so
        // resolution has to happen before anything else uses this path.
        let resolvedProductsDirectory = productsDirectory.resolvingSymlinksInPath()

        guard fileManager.fileExists(atPath: resolvedProductsDirectory.path) else {
            throw WorkspaceError.unreadable(
                path: resolvedProductsDirectory.path,
                underlying: "no such directory"
            )
        }

        let triple = resolvedProductsDirectory.deletingLastPathComponent().lastPathComponent
        let configuration = resolvedProductsDirectory.lastPathComponent
        let nestedDestination = destination
            .appendingPathComponent(triple, isDirectory: true)
            .appendingPathComponent(configuration, isDirectory: true)

        // Same reasoning as `cloneProducts`: refuses an existing
        // destination, so a stale prior clone under a reused `id` is
        // discarded wholesale rather than reconciled file-by-file.
        try? fileManager.removeItem(at: destination)

        do {
            // Only the `<triple>` level, not `nestedDestination` itself:
            // `clonefile`/`copyItem` both refuse an existing destination,
            // matching `cloneProducts`'s own contract.
            try fileManager.createDirectory(
                at: nestedDestination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            throw WorkspaceError.unwritable(path: nestedDestination.path, underlying: error.localizedDescription)
        }

        if supportsAPFSClone(), Self.clone(resolvedProductsDirectory, to: nestedDestination) {
            return destination
        }

        do {
            try fileManager.copyItem(at: resolvedProductsDirectory, to: nestedDestination)
        } catch {
            throw WorkspaceError.unwritable(path: nestedDestination.path, underlying: error.localizedDescription)
        }
        return destination
    }

    /// Clones a just-built products directory for a confirmation retest,
    /// choosing `cloneProducts`'s flat shape or `cloneProductsForConfirmation`'s
    /// nested `<triple>/<configuration>` shape depending on whether `adapter`
    /// conforms to `PackageManifestConfirmationRetesting` — the one decision
    /// `MutationRunner.establishConfirmationSandbox` and
    /// `MutationConfirmationCoordinator.confirmTimeout`'s own inner retest
    /// both need to make identically, factored out here so it cannot drift
    /// between the two call sites.
    ///
    /// Resolved via `packageManifestConfirmationRetesting(for:)`, never a
    /// bare `adapter is any PackageManifestConfirmationRetesting` — the
    /// latter only ever sees `adapter`'s own outermost declared
    /// conformances, so it fails silently for a `TestAdapterWrapping`
    /// wrapper (`PrioritizingTestAdapter`) around a genuinely-conforming
    /// SwiftPM adapter and this method would then produce the flat shape —
    /// wrong for `MutationConfirmationCoordinator.confirmKill`'s own
    /// identically-resolved dispatch, which would still correctly pick the
    /// manifest-aware retest path and hand it a flat clone `swift test
    /// --scratch-path` cannot use. Sharing the one resolution function is
    /// what keeps the sandbox's shape and the retest's dispatch from ever
    /// disagreeing.
    public func cloneProductsForConfirmationRetest(
        from productsDirectory: URL, id: String, for adapter: any TestAdapter
    ) async throws -> URL {
        try await packageManifestConfirmationRetesting(for: adapter) != nil
            ? cloneProductsForConfirmation(from: productsDirectory, id: id)
            : cloneProducts(from: productsDirectory, id: id)
    }

    /// Locates a plan-relative source file inside a sandbox.
    ///
    /// `MutationApplication` writes wherever it is pointed and says so; this is
    /// the layer that owns the guarantee it relies on. A plan is data, and data
    /// does not get to name `../../../etc/passwd` — nor to reach outside through
    /// a symlink that happens to live in the tree we copied.
    public nonisolated func resolveSourceURL(in sandbox: URL, relativePath: String) throws -> URL {
        let root = sandbox.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw WorkspaceError.pathOutsideSandbox(path: candidate.path, sandbox: root.path)
        }

        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else {
            throw WorkspaceError.pathOutsideSandbox(path: resolved.path, sandbox: root.path)
        }
        return resolved
    }

    // MARK: - Copy strategy

    /// Whether this filesystem can clone, determined by cloning rather than by
    /// asking: the answer depends on the volume, and a volume that reports APFS
    /// can still refuse (a firmlink crossing, a mounted image, a case-sensitive
    /// overlay). The only reliable probe is the syscall itself.
    public func supportsAPFSClone() -> Bool {
        if let known = cloneSupport { return known }
        let supported = Self.probeAPFSCloneSupport(at: scratchRoot, fileManager: fileManager)
        cloneSupport = supported
        return supported
    }

    /// The real `clonefile(2)` probe `supportsAPFSClone()` runs against
    /// this manager's own `scratchRoot`, pulled out as a reusable,
    /// side-effect-scoped-to-`directory` function so a caller with no
    /// `WorkspaceManager` instance -- `mutantkit doctor`'s module-cache
    /// diagnostic, in particular -- can ask the identical, real question
    /// about an arbitrary directory. Deliberately not routed through a
    /// throwaway `WorkspaceManager` instead: construction has its own side
    /// effects (creating the scratch root, wiping any pre-existing shared
    /// module cache there -- see `init`'s own doc comment) that a
    /// read-only diagnostic has no business triggering.
    public nonisolated static func probeAPFSCloneSupport(at directory: URL, fileManager: FileManager = .default) -> Bool {
        let source = directory.appendingPathComponent(".mutantkit-clone-probe")
        let destination = directory.appendingPathComponent(".mutantkit-clone-probe-clone")
        try? fileManager.removeItem(at: source)
        try? fileManager.removeItem(at: destination)
        defer {
            try? fileManager.removeItem(at: source)
            try? fileManager.removeItem(at: destination)
        }

        guard fileManager.createFile(atPath: source.path, contents: Data("probe".utf8)) else { return false }
        return clone(source, to: destination)
    }

    /// Copies one directory level, recursing rather than cloning the tree whole.
    ///
    /// `clonefile` would happily clone `projectRoot` in a single call, but the
    /// exclusions have to be honoured *before* the entries exist, not deleted
    /// afterwards — unlinking a cloned DerivedData costs more than never cloning
    /// it. Recursing keeps the exclusions exact; each file is still a clone, so
    /// no file data is duplicated either way.
    ///
    /// When `cleanSubtreeCloning` is on, a directory entry the clean-subtree
    /// index has *proven* contains no excluded content anywhere inside it
    /// skips this recursion entirely in favour of one whole-directory clone
    /// (`materializeWholeSubtree`) — see `CleanSubtreeIndex`'s own doc
    /// comment. Every other entry — dirty directories, files, symlinks —
    /// takes exactly the path it always has.
    private func populate(from source: URL, to destination: URL, relativePath: String) throws {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw WorkspaceError.unreadable(path: source.path, underlying: error.localizedDescription)
        }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            let relative = relativePath.isEmpty ? name : relativePath + "/" + name
            if isExcluded(name: name, relativePath: relative) { continue }

            // The scratch root usually lives inside the project it is testing;
            // descending into it would copy every other sandbox into this one.
            if entry.resolvingSymlinksInPath().standardizedFileURL.path == scratchRoot.path { continue }

            let target = destination.appendingPathComponent(name)
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

            // Symlinks are recreated, never followed: following one turns a link
            // into a copy of whatever it points at, which is both wrong and
            // unbounded when it points at a parent. Checked strictly before the
            // directory branch below, so a symlinked directory is never mistaken
            // for a whole-subtree-clone candidate, whatever the index says.
            if values?.isSymbolicLink == true {
                try recreateSymbolicLink(at: entry, to: target)
            } else if values?.isDirectory == true {
                if cleanSubtreeCloning, cachedCleanSubtreeIndex().isClean(relativePath: relative) {
                    try materializeWholeSubtree(entry, at: target)
                    continue
                }
                do {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                } catch {
                    throw WorkspaceError.unwritable(path: target.path, underlying: error.localizedDescription)
                }
                try populate(from: entry, to: target, relativePath: relative)
            } else {
                try materialize(entry, at: target)
            }
        }
    }

    /// Builds (on first use) or returns the cached clean-subtree index for
    /// this manager's `projectRoot`.
    ///
    /// One `WorkspaceManager` instance backs an entire run's worth of
    /// `createSandbox` calls — often hundreds, all against the same,
    /// unchanging `projectRoot` — and building this index costs roughly one
    /// extra metadata-only walk of the tree (`contentsOfDirectory` plus a
    /// `resourceValues` call per entry, no file data touched). Paying that
    /// once and reusing the result is the entire point: recomputing it per
    /// sandbox would make every sandbox pay a full extra walk on top of
    /// whatever the walk or the whole-subtree clones themselves cost,
    /// defeating the optimization before it starts.
    ///
    /// Actor-isolated, so "build once" needs no lock of its own: this type
    /// has no `await` inside it, so two concurrent `createSandbox` calls on
    /// the same instance simply run this method one after the other on the
    /// actor's executor, and whichever runs second finds `cleanSubtreeIndex`
    /// already set.
    private func cachedCleanSubtreeIndex() -> CleanSubtreeIndex {
        if let existing = cleanSubtreeIndex { return existing }
        let index = CleanSubtreeIndex.build(
            projectRoot: projectRoot,
            excludes: excludes,
            scratchRootPath: scratchRoot.path,
            fileManager: fileManager
        )
        cleanSubtreeIndex = index
        return index
    }

    /// Materializes a whole subtree the clean-subtree index has proven safe
    /// to clone in one call, instead of walking it entry-by-entry.
    ///
    /// Mirrors `materialize`'s clone-first, copy-as-fallback strategy
    /// exactly, just for a directory instead of one file — the same shape
    /// `cloneProducts` already uses for its own whole-directory case, reusing
    /// the same `clone(_:to:)` helper (`CLONE_NOFOLLOW`, so an internal
    /// symlink is reproduced as a symlink, never dereferenced — confirmed
    /// empirically by `WorkspaceManagerCleanSubtreeCloningTests`'s own
    /// symlink tests, for both this clone path and the `copyItem` fallback
    /// below).
    ///
    /// `destination` is removed first, unconditionally: `clonefile` refuses
    /// an existing destination, and a stale leftover here — a `--resume`
    /// against an already-partially-populated sandbox path, matching
    /// `ReproduceCommand`'s own comment about `createSandbox` being
    /// "intentionally incremental" — is safe to discard and re-clone whole
    /// rather than reconciled file-by-file: the end state has the same
    /// file-content bytes and relative-path layout either way (permission
    /// metadata is not guaranteed — see this type's own doc comment on
    /// `cleanSubtreeCloning`), this path just does not attempt
    /// `materialize`'s unchanged-file reuse for content the index has
    /// already proven can be cloned in one call regardless.
    private func materializeWholeSubtree(_ source: URL, at destination: URL) throws {
        if supportsAPFSClone() {
            try? fileManager.removeItem(at: destination)
            if Self.clone(source, to: destination) { return }
        }

        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw WorkspaceError.unwritable(path: destination.path, underlying: error.localizedDescription)
        }
    }

    /// Puts `source`'s contents at `destination` by the cheapest means available.
    private func materialize(_ source: URL, at destination: URL) throws {
        if supportsAPFSClone() {
            // clonefile refuses a destination that already exists.
            try? fileManager.removeItem(at: destination)
            if Self.clone(source, to: destination) { return }
        }

        // Without cloning, the next best thing is not copying: an identical file
        // already at the destination is one a re-populated sandbox can keep.
        if isUnchanged(source, at: destination) { return }

        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw WorkspaceError.unwritable(path: destination.path, underlying: error.localizedDescription)
        }
    }

    /// `nonisolated static`, not an instance method: it touches no actor
    /// state at all (a pure `clonefile(2)` wrapper), which is what lets
    /// `probeAPFSCloneSupport(at:fileManager:)` above call it without a
    /// `WorkspaceManager` instance to be isolated to. Every existing
    /// instance-method call site (`materialize`, `cloneProducts`) now
    /// spells it `Self.clone(...)` -- an actor's instance methods cannot
    /// resolve a `static` member of the same type by bare, unqualified
    /// name the way a struct's or class's can (confirmed by the compiler,
    /// not assumed), so both call sites needed that one-token change
    /// alongside this method's own `private func` -> `private nonisolated
    /// static func` widening.
    private nonisolated static func clone(_ source: URL, to destination: URL) -> Bool {
        // CLONE_NOFOLLOW keeps a symlink a symlink rather than cloning its target.
        clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0
    }

    private func isUnchanged(_ source: URL, at destination: URL) -> Bool {
        guard let sourceAttributes = try? fileManager.attributesOfItem(atPath: source.path),
              let destinationAttributes = try? fileManager.attributesOfItem(atPath: destination.path),
              let sourceSize = sourceAttributes[.size] as? Int,
              let destinationSize = destinationAttributes[.size] as? Int,
              sourceSize == destinationSize,
              let sourceDate = sourceAttributes[.modificationDate] as? Date,
              let destinationDate = destinationAttributes[.modificationDate] as? Date
        else { return false }
        return sourceDate == destinationDate
    }

    private func recreateSymbolicLink(at source: URL, to destination: URL) throws {
        let target: String
        do {
            target = try fileManager.destinationOfSymbolicLink(atPath: source.path)
        } catch {
            throw WorkspaceError.unreadable(path: source.path, underlying: error.localizedDescription)
        }

        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        } catch {
            throw WorkspaceError.unwritable(path: destination.path, underlying: error.localizedDescription)
        }
    }

    private func isExcluded(name: String, relativePath: String) -> Bool {
        Self.isExcluded(name: name, relativePath: relativePath, excludes: excludes)
    }

    /// The test `isExcluded(name:relativePath:)` applies against this
    /// instance's own `excludes`, factored out as `static` — and therefore
    /// `nonisolated`, callable without `await` — so `CleanSubtreeIndex.build`
    /// can classify a subtree using the *exact* same rule `populate` itself
    /// checks entries against, rather than a second implementation that
    /// could quietly drift from this one.
    static func isExcluded(name: String, relativePath: String, excludes: [String]) -> Bool {
        excludes.contains { pattern in
            fnmatch(pattern, name, 0) == 0 || fnmatch(pattern, relativePath, 0) == 0
        }
    }
}
