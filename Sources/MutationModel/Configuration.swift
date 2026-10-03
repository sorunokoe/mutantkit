import Foundation

/// User configuration, as written in `mutantkit.yml`.
///
/// `Codable` and format-agnostic: the CLI decodes it with Yams, tests decode the
/// same type from JSON. Every field has a default so a minimal config file stays
/// minimal, and `configurationHash` over the *resolved* value is what gets
/// recorded in the plan.
public struct Configuration: Codable, Sendable, Hashable {
    public var version: Int
    public var project: ProjectSettings
    public var sources: SourceSettings
    public var tests: TestSettings
    public var operators: OperatorSettings
    public var execution: ExecutionSettings
    public var timeouts: TimeoutSettings
    public var reports: [ReportKind]
    /// CI merge-decision policy. Not read by `plan`/`run`, only by `gate` —
    /// see `QualityGateSettings`'s own comment for why it is excluded from
    /// `configurationHash`.
    public var qualityGate: QualityGateSettings

    public init(
        version: Int = 1,
        project: ProjectSettings = ProjectSettings(),
        sources: SourceSettings = SourceSettings(),
        tests: TestSettings = TestSettings(),
        operators: OperatorSettings = OperatorSettings(),
        execution: ExecutionSettings = ExecutionSettings(),
        timeouts: TimeoutSettings = TimeoutSettings(),
        reports: [ReportKind] = [.console, .json],
        qualityGate: QualityGateSettings = QualityGateSettings()
    ) {
        self.version = version
        self.project = project
        self.sources = sources
        self.tests = tests
        self.operators = operators
        self.execution = execution
        self.timeouts = timeouts
        self.reports = reports
        self.qualityGate = qualityGate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        project = try container.decodeIfPresent(ProjectSettings.self, forKey: .project) ?? ProjectSettings()
        sources = try container.decodeIfPresent(SourceSettings.self, forKey: .sources) ?? SourceSettings()
        tests = try container.decodeIfPresent(TestSettings.self, forKey: .tests) ?? TestSettings()
        operators = try container.decodeIfPresent(OperatorSettings.self, forKey: .operators) ?? OperatorSettings()
        execution = try container.decodeIfPresent(ExecutionSettings.self, forKey: .execution) ?? ExecutionSettings()
        timeouts = try container.decodeIfPresent(TimeoutSettings.self, forKey: .timeouts) ?? TimeoutSettings()
        reports = try container.decodeIfPresent([ReportKind].self, forKey: .reports) ?? [.console, .json]
        qualityGate = try container.decodeIfPresent(QualityGateSettings.self, forKey: .qualityGate) ?? QualityGateSettings()
    }

    /// Hash of the canonical JSON encoding. Goes into the plan so that a plan
    /// executed under different settings is detectable rather than merely
    /// surprising. `qualityGate` is deliberately zeroed out first: it is pure
    /// CI merge policy, checked only at `gate` time, and must not make an
    /// otherwise-identical plan look different just because a threshold
    /// changed.
    public var configurationHash: String {
        var hashed = self
        hashed.qualityGate = QualityGateSettings()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(hashed) else { return ContentHash.of("<unencodable>") }
        return ContentHash.of(data)
    }

    /// Hash of only the settings that can reach a build command — the
    /// identity a lowered schemata plan is validated against
    /// (`SchemataPlan.validate`'s `buildArgumentsMismatch`).
    ///
    /// The whole configuration was used for this, which meant a lowered plan
    /// was *rejected* — and every chunk re-lowered — when anything at all in
    /// `mutantkit.yml` changed, including the report format. Same shape as
    /// the two identities `planningHash` and `IdentityScope` exist to fix:
    /// wider than the thing it guards, so it discards work that was still
    /// valid.
    ///
    /// ## Why this zeroes sections rather than naming the fields it keeps
    ///
    /// The tempting formulation is a list of the build-affecting settings.
    /// This codebase has already tried that and been burned by it, in this
    /// exact area: `SchemataPlan.deriveSchemataPlanID`'s own doc comment
    /// records that "a manually-enumerated list is exactly how the first
    /// version of this hash silently omitted `fallbackReason`,
    /// `conflictGroup`, and `target`/`module`/`product`", and the fix was to
    /// stop enumerating.
    ///
    /// So this names only what it *drops*, and drops whole sections rather
    /// than individual fields:
    ///
    /// - `sources` and `operators` decide which mutations exist. A change to
    ///   either produces a different plan, whose entries are already part of
    ///   `SchemataPlanID` — this identity does not need to catch it a second
    ///   time.
    /// - `timeouts` bounds how long a command is waited on, never what
    ///   command is invoked.
    /// - `reports` is output formatting; `qualityGate` is CI merge policy,
    ///   evaluated after a run has already finished.
    ///
    /// Everything else — `project` (scheme, destination, derived data),
    /// `tests` (which targets get built), and the *whole* of `execution`
    /// (where `incrementalBuild`, `sharedModuleCache`, `simulatorPool` and
    /// any build-affecting setting added later live) — is kept untouched.
    /// A field added to any of those is folded in automatically, and the
    /// cost of one that turns out not to matter is a re-lowering, never a
    /// lowered plan accepted against build arguments it was not built with.
    public var buildIdentityHash: String {
        var hashed = self
        hashed.sources = SourceSettings()
        hashed.operators = OperatorSettings()
        hashed.timeouts = TimeoutSettings()
        hashed.reports = []
        hashed.qualityGate = QualityGateSettings()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(hashed) else { return ContentHash.of("<unencodable>") }
        return ContentHash.of(data)
    }

    /// Hash of only the settings that decide *what gets planned* — which
    /// mutants exist at all, not how they are then executed.
    ///
    /// `configurationHash` above covers the whole configuration, which makes
    /// it the right identity for "was this produced under the same settings"
    /// and the wrong one for "would re-planning produce a different plan".
    /// Using it for the second question means any execution-only edit
    /// between `plan` and `run` — turning on `selectCoveringTests`, changing
    /// `workers`, adding a report format — reports a plan/configuration
    /// mismatch that does not exist. Observed in the field: adding
    /// `execution.selectCoveringTests: true` to `mutantkit.yml` after
    /// planning warned that the plan no longer matched the configuration,
    /// which is alarming, unactionable, and false.
    ///
    /// Scoped by what planning actually reads, which is enumerable:
    /// `MutationPlanner.makePlan` reads `sources`, `operators`,
    /// `execution.budget` and `execution.diffBase`; `PlanCommand` resolves
    /// SwiftPM's live source set from `project` before handing it over. The
    /// rest — `tests`, `timeouts`, `reports`, `qualityGate`, and every other
    /// `execution` field — is read only while executing a plan that already
    /// exists.
    ///
    /// Everything outside `execution` is zeroed by name, so a *new* top-level
    /// section is folded in by default; that is the conservative direction,
    /// since an unnecessary input costs a false warning and a missing one
    /// costs a missed real change. Inside `execution` the two planning
    /// fields are named explicitly instead, which leaves one obligation: an
    /// execution field added later that does change what gets planned must be
    /// preserved here too.
    public var planningHash: String {
        var hashed = self
        hashed.tests = TestSettings()
        hashed.timeouts = TimeoutSettings()
        hashed.reports = []
        hashed.qualityGate = QualityGateSettings()
        let planningExecution = (budget: execution.budget, diffBase: execution.diffBase)
        hashed.execution = ExecutionSettings()
        hashed.execution.budget = planningExecution.budget
        hashed.execution.diffBase = planningExecution.diffBase
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(hashed) else { return ContentHash.of("<unencodable>") }
        return ContentHash.of(data)
    }
}

// MARK: - Project

public enum ProjectKind: String, Codable, Sendable {
    /// Detect from the directory contents. What `init` writes by default.
    case auto
    /// Swift package tested with `swift test` on the host.
    case swiftPackageMacOS
    /// Swift package for a non-host Apple platform (e.g. UIKit-dependent code).
    /// Needs `xcodebuild` against a simulator destination — `swift test` alone
    /// runs on the host toolchain and cannot see these frameworks.
    case swiftPackageApple
    case xcodeProject
    case xcodeWorkspace
}

public struct ProjectSettings: Codable, Sendable, Hashable {
    public var kind: ProjectKind
    public var path: String?
    public var scheme: String?
    public var destination: String?
    public var derivedDataPath: String?
    /// Names of entries next to the project root that each sandbox should see
    /// next to itself too, for builds that reach one level out of the root
    /// (e.g. `.binaryTarget(path: "../../shared/App.xcframework")` when
    /// `--project-root` is a monorepo's iOS directory). See
    /// `WorkspaceManager.linkProjectRootSiblings`.
    public var linkSiblings: [String]?

    public init(
        kind: ProjectKind = .auto,
        path: String? = nil,
        scheme: String? = nil,
        destination: String? = nil,
        derivedDataPath: String? = nil,
        linkSiblings: [String]? = nil
    ) {
        self.kind = kind
        self.path = path
        self.scheme = scheme
        self.destination = destination
        self.derivedDataPath = derivedDataPath
        self.linkSiblings = linkSiblings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(ProjectKind.self, forKey: .kind) ?? .auto
        path = try container.decodeIfPresent(String.self, forKey: .path)
        scheme = try container.decodeIfPresent(String.self, forKey: .scheme)
        destination = try container.decodeIfPresent(String.self, forKey: .destination)
        derivedDataPath = try container.decodeIfPresent(String.self, forKey: .derivedDataPath)
        linkSiblings = try container.decodeIfPresent([String].self, forKey: .linkSiblings)
    }
}

// MARK: - Sources

public struct SourceSettings: Codable, Sendable, Hashable {
    public var include: [String]
    public var exclude: [String]

    public init(include: [String] = ["Sources/**"], exclude: [String] = defaultExcludes) {
        self.include = include
        self.exclude = exclude
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        include = try container.decodeIfPresent([String].self, forKey: .include) ?? ["Sources/**"]
        exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? Self.defaultExcludes
    }

    /// Generated and mock code produces mutants nobody will ever act on, which
    /// is the main way a mutation report becomes noise people stop reading.
    public static let defaultExcludes = [
        "**/Generated/**",
        "**/*.generated.swift",
        "**/*Mock*.swift",
        "**/*Mocks*.swift",
        "**/.build/**",
        "**/DerivedData/**",
        "**/Pods/**",
        "**/Carthage/**"
    ]
}

// MARK: - Tests

public struct TestSettings: Codable, Sendable, Hashable {
    public var targets: [String]
    /// Extra arguments appended to the test invocation, as a list — never a
    /// shell string.
    public var extraArguments: [String]
    /// Run a Swift package's tests in parallel (`swift test --parallel`).
    ///
    /// **Off by default, and the default is the safe one.** Turning this on buys
    /// better diagnostics at the cost of a real correctness hazard, so it is the
    /// user's decision to make, not ours to make for them.
    ///
    /// What it buys: SwiftPM only writes the XCTest half of `--xunit-output`
    /// when tests run in parallel. Serially, an XCTest package reports no counts
    /// at all, so `inspect` cannot say which test caught a mutant. Outcomes stay
    /// correct either way — the verdict comes from the exit code — but the
    /// detail is lost.
    ///
    /// What it risks: a suite that is not parallel-safe flakes. A flaky failure
    /// during a mutant's run is indistinguishable from the mutant being caught,
    /// so it is recorded as `killedByAssertion` and the mutation score is
    /// silently inflated. An inflated score is the specific lie this tool exists
    /// to prevent, and unlike a missing count it announces nothing.
    ///
    /// Only enable it if your suite already passes reliably under
    /// `swift test --parallel`.
    public var parallel: Bool

    public init(targets: [String] = [], extraArguments: [String] = [], parallel: Bool = false) {
        self.targets = targets
        self.extraArguments = extraArguments
        self.parallel = parallel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targets = try container.decodeIfPresent([String].self, forKey: .targets) ?? []
        extraArguments = try container.decodeIfPresent([String].self, forKey: .extraArguments) ?? []
        parallel = try container.decodeIfPresent(Bool.self, forKey: .parallel) ?? false
    }
}

// MARK: - Operators

public struct OperatorSettings: Codable, Sendable, Hashable {
    public var profile: OperatorProfile
    public var disable: [String]
    public var enable: [String]
    /// `swift.core.side-effect-call-removal`'s own configuration. `nil`
    /// (the default) means no calls are excluded beyond the operator's
    /// own built-in denylist (`fatalError`, `preconditionFailure`, ...).
    ///
    /// A dedicated, operator-scoped nested struct rather than a new
    /// top-level flat field: `OperatorSettings` otherwise applies
    /// uniformly to every operator (`profile`/`enable`/`disable`), and a
    /// call-name exclusion list is meaningless to every operator except
    /// this one. Nesting it under the operator's own name keeps that
    /// scoping visible in the config file itself, and gives a natural
    /// place for a future operator's own settings without cluttering this
    /// struct with unrelated fields.
    public var sideEffectCallRemoval: SideEffectCallRemovalSettings?

    public init(
        profile: OperatorProfile = .default,
        disable: [String] = [],
        enable: [String] = [],
        sideEffectCallRemoval: SideEffectCallRemovalSettings? = nil
    ) {
        self.profile = profile
        self.disable = disable
        self.enable = enable
        self.sideEffectCallRemoval = sideEffectCallRemoval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decodeIfPresent(OperatorProfile.self, forKey: .profile) ?? .default
        disable = try container.decodeIfPresent([String].self, forKey: .disable) ?? []
        enable = try container.decodeIfPresent([String].self, forKey: .enable) ?? []
        sideEffectCallRemoval = try container.decodeIfPresent(
            SideEffectCallRemovalSettings.self, forKey: .sideEffectCallRemoval
        )
    }
}

/// Per-call exclusion for `swift.core.side-effect-call-removal`, the
/// closest analogue to Muter's `excludeCalls` (see
/// `MuterConfigImporter`, which maps one directly onto the other during
/// `migrate --from-muter`).
///
/// Matched on the called function/method's own base name only (the
/// simple name after the last `.`, e.g. `record` for both `logger.record(...)`
/// and `analytics.record(...)`) — the same pragmatic, not-symbol-resolved
/// approach `LifecycleSuperCallRemovalOperator`'s method-name denylist and
/// `OperatorExclusions`' builder-property-name matching already take
/// throughout this catalog. This means an exclusion is necessarily
/// coarser than Muter's own (which can, in principle, exclude a
/// specific receiver's method), but requires no type information to
/// apply — matching the same trade-off Muter's own `excludeCalls`
/// warns about (\"Doesn't support overloading currently - all function
/// calls with a matching name will be skipped\").
public struct SideEffectCallRemovalSettings: Codable, Sendable, Hashable {
    public var excludeCalls: [String]

    public init(excludeCalls: [String] = []) {
        self.excludeCalls = excludeCalls
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        excludeCalls = try container.decodeIfPresent([String].self, forKey: .excludeCalls) ?? []
    }
}

// MARK: - Execution

// `ExecutionSettings` itself lives in ExecutionSettings.swift, split out to
// keep this file under the repo's own `file_length` threshold — see that
// file's header comment. `BudgetSettings` and its supporting types stay
// here since `ExecutionSettings` composes them, not the other way round.

/// How a budget narrows the discovered set down to `maxMutants`.
///
/// `nil` on `BudgetSettings.stratifyBy` preserves the original two-strategy
/// split (a `seed` draws a pure random sample; its absence round-robins by
/// file then operator) — existing configs and their exact selections are
/// unaffected by this type's addition. `.subtype` is the only case: it
/// stratifies by operator *and* by the exact original → replacement pair,
/// not just the operator. An operator that emits several distinct
/// replacements — relational-operator-replacement emits ten — is really
/// several different claims about the source, and a sample that does not
/// separate them lets whichever pair is most common in the codebase crowd
/// out the rest, exactly as an unstratified sample would. Reproducible from
/// `(plan, seed)`: the same seed always draws the same mutants, but two
/// seeds draw two different within-stratum orderings, never two different
/// sets of strata.
public enum BudgetStratification: String, Codable, Sendable {
    /// Stratifies by operator *and* by the exact original → replacement
    /// pair, round-robin over strata in **alphabetical stratum-key order**.
    /// That fixed order is a real limitation, not just a historical quirk:
    /// when the number of distinct strata exceeds the budget, the strata
    /// that sort later never contribute at all, regardless of how common
    /// they are — this is what happened measuring `ternary-branch-swap` and
    /// `unary-not-removal` against a real project (0 of either sampled out
    /// of a 1242-candidate pool at a 100-mutant budget; see the internal
    /// corpus-validation notes' "Corpus sampling caveats" section, not part
    /// of this public repo). A seed only decides which *member* of an
    /// already-included stratum is drawn, never which strata are included.
    /// Kept exactly as-is — this is what makes it additive rather than a
    /// silent behavior change for every existing config that set it.
    case subtype
    /// Balances by operator first, then by subtype within each operator —
    /// see `BudgetSettings.minimumPerOperator` and
    /// `BudgetSelector.selectByOperatorSubtype` for the full contract. Unlike
    /// `.subtype`, every ordering decision this mode makes — which
    /// operators are included when the budget can't cover all of them,
    /// which subtypes are included within an operator's slice, and which
    /// members are drawn — is a function of `seed`, not of alphabetical
    /// sort order.
    case operatorSubtype
}

/// Opt-in switch between v1's `stratifyBy`-driven selection and Budget
/// Selection v2's two-level allocator (ADR-0007). `nil`/`.v1` (the default)
/// keeps `stratifyBy`/`minimumPerOperator` in full effect, byte-identical to
/// existing configs (ADR-0007 invariant 8, Choice 1 — v2 ships opt-in only
/// this milestone). `.v2` routes through `BudgetSelectorV2` instead, using
/// `minimumPerStratum`/`weight` and ignoring `stratifyBy`/`minimumPerOperator`.
public enum BudgetSelectionAlgorithm: String, Codable, Sendable {
    case v1
    case v2
}

public struct BudgetSettings: Codable, Sendable, Hashable {
    public var maxMutants: Int?
    public var maxDurationSeconds: Double?
    /// Required if `maxMutants` is set and selection must sample — determinism
    /// is the default, so any randomness has to be named explicitly.
    public var seed: UInt64?
    public var stratifyBy: BudgetStratification?
    /// Minimum mutants reserved per enabled operator with >=1 eligible
    /// candidate, under `stratifyBy: .operatorSubtype`. Defaults to 1 —
    /// enough to get *some* signal per operator, which is the entire point
    /// of that mode. Ignored under `.subtype` and `nil`. Ignored entirely
    /// under `selection: .v2` — see `minimumPerStratum`.
    public var minimumPerOperator: Int?
    /// Opts into Budget Selection v2 (ADR-0007). See
    /// `BudgetSelectionAlgorithm`'s doc comment.
    public var selection: BudgetSelectionAlgorithm?
    /// `selection: .v2` only: the outer stratum's (operator's) Phase 1
    /// minimum-reservation floor — the v2 analogue of `minimumPerOperator`.
    /// Defaults to 1 when `.v2` is active and this is unset. Ignored under
    /// `.v1`/`nil`.
    public var minimumPerStratum: Int?
    /// `selection: .v2` only: optional per-operator Phase 2 weight (ADR-0007
    /// B.3), keyed by operator ID. Empty/unset means equal-share. If any
    /// entry is configured, every operator with an eligible candidate must
    /// be configured — a partial configuration is a config-load error (see
    /// `BudgetSelectorV2.validateWeightConfiguration`). Ignored under
    /// `.v1`/`nil`.
    public var weight: [String: Int]?

    public init(
        maxMutants: Int? = nil,
        maxDurationSeconds: Double? = nil,
        seed: UInt64? = nil,
        stratifyBy: BudgetStratification? = nil,
        minimumPerOperator: Int? = nil,
        selection: BudgetSelectionAlgorithm? = nil,
        minimumPerStratum: Int? = nil,
        weight: [String: Int]? = nil
    ) {
        self.maxMutants = maxMutants
        self.maxDurationSeconds = maxDurationSeconds
        self.seed = seed
        self.stratifyBy = stratifyBy
        self.minimumPerOperator = minimumPerOperator
        self.selection = selection
        self.minimumPerStratum = minimumPerStratum
        self.weight = weight
    }

    /// `sampling`/`stratifyWithinOperatorBy` were a same-day-superseded
    /// design: `sampling: balancedByOperator` + `stratifyWithinOperatorBy`
    /// shipped and were replaced by `stratifyBy: operatorSubtype` +
    /// `minimumPerOperator` before either key was used in any committed
    /// config. Decoding them silently (as unknown-key-ignored) would let a
    /// config written against the old key names quietly stop balancing by
    /// operator at all — the exact silent starvation this mode exists to
    /// prevent — so they decode as an explicit, actionable error instead.
    private enum LegacyCodingKeys: String, CodingKey {
        case sampling
        case stratifyWithinOperatorBy
    }

    public init(from decoder: Decoder) throws {
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if legacy.contains(.sampling) || legacy.contains(.stratifyWithinOperatorBy) {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: legacy.codingPath,
                debugDescription: """
                execution.budget.sampling and execution.budget.stratifyWithinOperatorBy no longer \
                exist. Replace `sampling: balancedByOperator` with `stratifyBy: operatorSubtype` \
                (and move any `minimumPerOperator` to execution.budget directly, if not already \
                there); `stratifyWithinOperatorBy` has no replacement — subtype stratification is \
                unconditional under `stratifyBy: operatorSubtype`.
                """
            ))
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxMutants = try container.decodeIfPresent(Int.self, forKey: .maxMutants)
        maxDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .maxDurationSeconds)
        seed = try container.decodeIfPresent(UInt64.self, forKey: .seed)
        stratifyBy = try container.decodeIfPresent(BudgetStratification.self, forKey: .stratifyBy)
        minimumPerOperator = try container.decodeIfPresent(Int.self, forKey: .minimumPerOperator)
        selection = try container.decodeIfPresent(BudgetSelectionAlgorithm.self, forKey: .selection)
        minimumPerStratum = try container.decodeIfPresent(Int.self, forKey: .minimumPerStratum)
        weight = try container.decodeIfPresent([String: Int].self, forKey: .weight)
    }
}

// MARK: - Timeouts

public enum TimeoutStrategy: String, Codable, Sendable {
    /// Fixed `maximum` for every mutant.
    case fixed
    /// Derived from the observed baseline duration times `multiplier`, clamped
    /// to [`minimum`, `maximum`].
    case adaptive
}

public struct MutantTimeoutSettings: Codable, Sendable, Hashable {
    public var strategy: TimeoutStrategy
    public var multiplier: Double
    public var minimumSeconds: Double
    public var maximumSeconds: Double
    /// Flat time added to the adaptive limit, on top of `baseline × multiplier`.
    ///
    /// The baseline measures a suite that *passes*. A mutant that gets killed
    /// makes it fail, and failing costs extra fixed work that the baseline never
    /// paid for: xcodebuild collects diagnostics and attachments and finishes
    /// writing the result bundle. That cost is additive and does not shrink with
    /// the suite, so on a small suite a pure multiplier under-budgets precisely
    /// the mutants that are about to be killed — reporting them as `timedOut`,
    /// which is excluded from the score. Killed mutants would then quietly
    /// disappear from both sides of the ratio.
    public var overheadAllowanceSeconds: Double

    public init(
        strategy: TimeoutStrategy = .adaptive,
        multiplier: Double = 3,
        minimumSeconds: Double = 30,
        maximumSeconds: Double = 300,
        overheadAllowanceSeconds: Double = 60
    ) {
        self.strategy = strategy
        self.multiplier = multiplier
        self.minimumSeconds = minimumSeconds
        self.maximumSeconds = maximumSeconds
        self.overheadAllowanceSeconds = overheadAllowanceSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        strategy = try container.decodeIfPresent(TimeoutStrategy.self, forKey: .strategy) ?? .adaptive
        multiplier = try container.decodeIfPresent(Double.self, forKey: .multiplier) ?? 3
        minimumSeconds = try DurationDecoding.seconds(container, .minimum) ?? 30
        maximumSeconds = try DurationDecoding.seconds(container, .maximum) ?? 300
        overheadAllowanceSeconds = try DurationDecoding.seconds(container, .overheadAllowance) ?? 60
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(strategy, forKey: .strategy)
        try container.encode(multiplier, forKey: .multiplier)
        try container.encode(minimumSeconds, forKey: .minimum)
        try container.encode(maximumSeconds, forKey: .maximum)
        try container.encode(overheadAllowanceSeconds, forKey: .overheadAllowance)
    }

    enum CodingKeys: String, CodingKey {
        case strategy, multiplier, minimum, maximum, overheadAllowance
    }

    /// Resolves the wall-clock limit for one mutant given the measured baseline.
    ///
    /// A mutant that removes a `resume` on a continuation hangs forever; this
    /// number is the only thing that ends it. It has to be generous enough that a
    /// `timedOut` means "this mutant hangs" rather than "the limit was too tight",
    /// because the two are indistinguishable in the result and only the first is
    /// worth telling anyone about.
    public func resolve(baselineDuration: Double) -> Double {
        switch strategy {
        case .fixed:
            maximumSeconds
        case .adaptive:
            // Scale with the suite, then add the flat cost of failing.
            min(max(baselineDuration * multiplier + overheadAllowanceSeconds, minimumSeconds), maximumSeconds)
        }
    }
}

public struct TimeoutSettings: Codable, Sendable, Hashable {
    public var baselineSeconds: Double
    public var mutant: MutantTimeoutSettings
    /// How long a process group gets to exit on SIGTERM before SIGKILL.
    public var terminationGracePeriodSeconds: Double

    public init(
        baselineSeconds: Double = 600,
        mutant: MutantTimeoutSettings = MutantTimeoutSettings(),
        terminationGracePeriodSeconds: Double = 5
    ) {
        self.baselineSeconds = baselineSeconds
        self.mutant = mutant
        self.terminationGracePeriodSeconds = terminationGracePeriodSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baselineSeconds = try DurationDecoding.seconds(container, .baseline) ?? 600
        mutant = try container.decodeIfPresent(MutantTimeoutSettings.self, forKey: .mutant)
            ?? MutantTimeoutSettings()
        terminationGracePeriodSeconds = try container.decodeIfPresent(
            Double.self, forKey: .terminationGracePeriod
        ) ?? 5
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baselineSeconds, forKey: .baseline)
        try container.encode(mutant, forKey: .mutant)
        try container.encode(terminationGracePeriodSeconds, forKey: .terminationGracePeriod)
    }

    enum CodingKeys: String, CodingKey {
        case baseline, mutant, terminationGracePeriod
    }
}

/// Decodes a duration written either as a number of seconds or as `10m`/`90s`.
///
/// Both spellings are accepted because a config file is written by hand: `2m` is
/// what someone means, and `120` is what they will paste from a script.
enum DurationDecoding {
    static func seconds<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        _ key: Key
    ) throws -> Double? {
        // A numeric value decodes directly; a string one makes this throw, which
        // is the signal to try parsing it as a duration literal instead.
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        guard let text = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return DurationParser.seconds(from: text)
    }
}

/// Parses `10m`, `90s`, `1h30m` and bare numbers (seconds) from config.
public enum DurationParser {
    public static func seconds(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let bare = Double(trimmed) { return bare }

        var total: Double = 0
        var current = ""
        var matched = false

        for character in trimmed {
            if character.isNumber || character == "." {
                current.append(character)
                continue
            }
            guard let value = Double(current) else { return nil }
            let multiplier: Double
            switch character {
            case "h": multiplier = 3600
            case "m": multiplier = 60
            case "s": multiplier = 1
            default: return nil
            }
            total += value * multiplier
            current = ""
            matched = true
        }

        return matched && current.isEmpty ? total : nil
    }
}

// MARK: - Reports

public enum ReportKind: String, Codable, Sendable, CaseIterable {
    case console
    case xcode
    case json
    case strykerJSON = "stryker-json"
    case html
    case ciSummary = "ci-summary"
    /// SonarQube/SonarCloud's generic issue import format. Named `sonar`
    /// rather than `sonar-json` to match the plain single-word convention
    /// most cases already use (`console`, `xcode`, `json`, `html`) — the
    /// hyphenated names exist only where a bare word would be ambiguous
    /// (`stryker-json` vs. our own `json`; `ci-summary` has no one-word
    /// equivalent at all), which "sonar" does not need.
    case sonar
    /// GitHub Actions `::warning::`/`::error::` workflow-command
    /// annotations (`GitHubActionsReporter`) — printed to stdout during a
    /// run, like `console`/`xcode`, never written to a file; see that
    /// reporter's own doc comment for the exact format and escaping rules.
    case githubActions = "github-actions"
    /// SARIF 2.1.0 (`SarifReporter`) — the format GitHub code scanning,
    /// Azure DevOps, and most SAST dashboards consume. Bare `sarif`, not
    /// `sarif-json`, matching `sonar`'s reasoning above: no existing case
    /// makes it ambiguous.
    case sarif
}

// MARK: - Quality gate

/// CI merge-decision policy, checked out separately at `gate` time — see
/// `GateCommand` and `QualityGateThresholds`. Deliberately excluded from
/// `Configuration.configurationHash` (see that property's own comment):
/// tightening or loosening a CI threshold does not change what gets
/// mutated, so it must not invalidate an in-progress plan or checkpoint.
public struct QualityGateSettings: Codable, Sendable, Hashable {
    public struct ScoreThreshold: Codable, Sendable, Hashable {
        /// Percent, e.g. `70` for 70%.
        public var minimum: Double?

        public init(minimum: Double? = nil) {
            self.minimum = minimum
        }
    }

    public struct RegressionThreshold: Codable, Sendable, Hashable {
        /// Percentage points, e.g. `2` for 2%. Requires `gate --baseline`.
        public var maximumDrop: Double?

        public init(maximumDrop: Double? = nil) {
            self.maximumDrop = maximumDrop
        }
    }

    public struct SurvivedThreshold: Codable, Sendable, Hashable {
        public var newMaximum: Int?

        public init(newMaximum: Int? = nil) {
            self.newMaximum = newMaximum
        }
    }

    public struct IntegrityThreshold: Codable, Sendable, Hashable {
        /// Written for symmetry with the other four keys, not because a
        /// nonzero tolerance is supported: the gate already fails closed
        /// on any integrity violation unconditionally (see
        /// `QualityGate.evaluate`), and `ConfigurationLoader`/`gate` reject
        /// any value here other than `0` rather than silently accept a
        /// setting that would weaken that guarantee.
        public var maximum: Int?

        public init(maximum: Int? = nil) {
            self.maximum = maximum
        }
    }

    public var testedScore: ScoreThreshold?
    public var effectiveScore: ScoreThreshold?
    public var regression: RegressionThreshold?
    public var survived: SurvivedThreshold?
    public var integrityViolations: IntegrityThreshold?

    public init(
        testedScore: ScoreThreshold? = nil,
        effectiveScore: ScoreThreshold? = nil,
        regression: RegressionThreshold? = nil,
        survived: SurvivedThreshold? = nil,
        integrityViolations: IntegrityThreshold? = nil
    ) {
        self.testedScore = testedScore
        self.effectiveScore = effectiveScore
        self.regression = regression
        self.survived = survived
        self.integrityViolations = integrityViolations
    }

    /// Converts to the fraction/count-based thresholds `QualityGate.evaluate`
    /// actually checks. Throws if `integrityViolations.maximum` is set to
    /// anything but `0` (see that field's own comment).
    public func resolvedThresholds() throws -> QualityGateThresholds {
        if let maximum = integrityViolations?.maximum, maximum != 0 {
            throw QualityGateSettingsError.nonzeroIntegrityTolerance(maximum)
        }
        return QualityGateThresholds(
            minimumTested: testedScore?.minimum.map { $0 / 100 },
            minimumEffective: effectiveScore?.minimum.map { $0 / 100 },
            maximumSurvivors: nil,
            regressionMaximumDrop: regression?.maximumDrop.map { $0 / 100 },
            newSurvivorsMaximum: survived?.newMaximum
        )
    }
}

public enum QualityGateSettingsError: Error, CustomStringConvertible {
    case nonzeroIntegrityTolerance(Int)

    public var description: String {
        switch self {
        case let .nonzeroIntegrityTolerance(value):
            "qualityGate.integrityViolations.maximum must be 0 (found \(value)): MutantKit always "
                + "fails closed on an integrity violation, and this cannot be configured to tolerate one."
        }
    }
}
