internal import CInfomap
internal import CxxStdlib

/// Errors surfaced by the engine. All cases carry human-readable context —
/// the C++ core's error strings are preserved verbatim in `engineFailure`.
public enum InfomapError: Error, Sendable, Equatable {
    /// The option/network combination is known-broken or meaningless.
    ///
    /// The standing case: Bayesian regularization combined with a bipartite
    /// node-type declaration, which the vendored core (Infomap 2.15.1)
    /// either aborts on or — worse — answers with a silently degenerate
    /// partition. Guarded here until fixed upstream: iliasaz/infomap#1.
    case unsupportedConfiguration(reason: String)
    /// The network cannot be run (no links, non-positive or non-finite
    /// weight, node IDs inconsistent with `bipartiteStartID`, …).
    case invalidNetwork(reason: String)
    /// The C++ core reported an error; message preserved verbatim.
    case engineFailure(message: String)
}

/// The one operation consumers depend on. Kept as a protocol so mnemosis
/// tests can substitute a fixture engine (golden partitions from the Python
/// reference implementation) without linking the C++ core.
public protocol InfomapRunning: Sendable {
    /// Runs map-equation minimization and returns the full partition.
    ///
    /// Implementation contract:
    /// - The C++ call is blocking; it must run off the Swift cooperative
    ///   pool. The core offers no cancellation hook — an in-flight run is
    ///   non-abortable, so size inputs accordingly (the 369K-link validation
    ///   corpus ran in ~40 s). Cancellation is honored at the safe point
    ///   before the run starts: a run requested from an already-cancelled
    ///   task throws `CancellationError` instead of doing dead work.
    /// - Equal `(network, options)` including seed ⇒ identical `Partition`
    ///   on a given platform/build (bit-reproducibility is what makes the
    ///   G2r stability regression meaningful). Across platforms, low trial
    ///   counts can settle in different near-tie optima — pin trials high
    ///   enough for the search to reach the settled optimum.
    /// - Must throw ``InfomapError/unsupportedConfiguration(reason:)`` for
    ///   `options.regularization != .off && network.bipartiteStartID != nil`
    ///   while iliasaz/infomap#1 is unfixed in the vendored pin.
    func run(_ network: FlowNetwork, options: InfomapOptions) async throws -> Partition
}

/// The production engine over the vendored Infomap C++ core.
///
/// An actor: the core is not documented thread-safe, so runs serialize here.
/// Beyond the actor, every C++ call in the process funnels through the
/// single ``BlockingWorker`` thread — the vendored core routes logging
/// through mutable statics (`utils/Log`) written during construction and
/// every run, so even distinct engine instances must not overlap. Multiple
/// engines therefore buy pipelining of Swift-side conversion at most, not
/// concurrent C++ runs.
public actor InfomapEngine: InfomapRunning {
    public static let shared = InfomapEngine()

    public init() {}

    public func run(_ network: FlowNetwork, options: InfomapOptions) async throws -> Partition {
        try Task.checkCancellation()
        try Self.validate(network: network, options: options)
        let input = Self.bridgeInput(network: network, options: options)
        let outcome = await BlockingWorker.shared.run {
            Self.runCore(input)
        }
        return try outcome.get()
    }

    // MARK: Pre-flight validation

    /// Pre-flight checks: the iliasaz/infomap#1 guard *is* part of the
    /// contract, and the rest converts conditions the core would answer with
    /// a cryptic error — or, for a dangling `bipartiteStartID`, silently
    /// wrong flow — into typed errors before any C++ runs.
    static func validate(network: FlowNetwork, options: InfomapOptions) throws {
        if network.links.isEmpty {
            throw InfomapError.invalidNetwork(reason: "network has no links")
        }
        if let bad = network.links.first(where: { !($0.weight > 0) || !$0.weight.isFinite }) {
            throw InfomapError.invalidNetwork(
                reason: "link \(bad.source)→\(bad.target) has non-positive or non-finite weight \(bad.weight)"
            )
        }
        if let bad = network.links.first(where: {
            $0.source < 0 || $0.target < 0 || $0.source > UInt32.max || $0.target > UInt32.max
        }) {
            throw InfomapError.invalidNetwork(
                reason: "link \(bad.source)→\(bad.target) has a node ID outside the engine's 0...\(UInt32.max) range"
            )
        }
        if let start = network.bipartiteStartID {
            let ids = network.nodeIDs
            // The core resolves the start ID through its node-index map; a
            // non-existent ID silently corrupts the bipartite flow split.
            guard start > 0, ids.contains(start), let minID = ids.min(), minID < start else {
                throw InfomapError.invalidNetwork(
                    reason: """
                    bipartiteStartID \(start) must be positive, be a linked feature node ID, \
                    and leave at least one primary node below it
                    """
                )
            }
        }
        if network.bipartiteStartID != nil, options.regularization != .off {
            throw InfomapError.unsupportedConfiguration(
                reason: """
                Bayesian regularization combined with a bipartite declaration is \
                engine-bugged in Infomap 2.15.1 (aborts with negative enter flow, or \
                silently returns a degenerate partition) — see iliasaz/infomap#1. \
                Either drop the bipartite declaration for regularized runs (unipartite \
                prior; conservative) or run unregularized.
                """
            )
        }
        if options.trials < 1 {
            throw InfomapError.unsupportedConfiguration(reason: "trials must be ≥ 1, got \(options.trials)")
        }
        if options.seed < 1 || options.seed > UInt64(UInt32.max) {
            throw InfomapError.unsupportedConfiguration(
                reason: "seed must be in 1...\(UInt32.max) (core constraint), got \(options.seed)"
            )
        }
        if !(options.markovTime > 0) || !options.markovTime.isFinite {
            throw InfomapError.unsupportedConfiguration(reason: "markovTime must be positive and finite, got \(options.markovTime)")
        }
        if case .bayesian(let strength) = options.regularization,
           !(strength > 0) || !strength.isFinite {
            throw InfomapError.unsupportedConfiguration(
                reason: "regularization strength must be positive and finite, got \(strength)"
            )
        }
        if let metadata = options.metadata {
            if !(metadata.rate >= 0) || !metadata.rate.isFinite {
                throw InfomapError.unsupportedConfiguration(reason: "metadata rate must be non-negative and finite, got \(metadata.rate)")
            }
            if let bad = metadata.labels.first(where: {
                $0.key < 0 || $0.key > UInt32.max || $0.value < 0 || $0.value > Int32.max
            }) {
                throw InfomapError.invalidNetwork(
                    reason: """
                    metadata entry \(bad.key): \(bad.value) is outside the engine's range — \
                    categories must be in 0...\(Int32.max) (the core reserves -1 for unlabeled nodes)
                    """
                )
            }
            // The core silently drops labels for node IDs it never saw
            // (metadata is stamped by looking each *network* node up in the
            // label map, not the reverse) — same silent-failure class as a
            // dangling bipartiteStartID, so same treatment.
            let ids = network.nodeIDs
            if let dangling = metadata.labels.keys.first(where: { !ids.contains($0) }) {
                throw InfomapError.invalidNetwork(
                    reason: "metadata labels node \(dangling), which has no links in the network — the core would silently ignore it"
                )
            }
        }
    }

    // MARK: Bridge input

    /// Everything the C++ call needs, as Sendable value types — assembled on
    /// the actor, consumed on the dedicated thread.
    struct BridgeInput: Sendable {
        var flags: String
        var sources: [UInt32]
        var targets: [UInt32]
        var weights: [Double]
        var bipartiteStartID: Int64
        var metaNodes: [UInt32]
        var metaCategories: [Int32]
    }

    static func bridgeInput(network: FlowNetwork, options: InfomapOptions) -> BridgeInput {
        var metaNodes: [UInt32] = []
        var metaCategories: [Int32] = []
        if let metadata = options.metadata {
            for (node, category) in metadata.labels.sorted(by: { $0.key < $1.key }) {
                metaNodes.append(UInt32(node))
                metaCategories.append(Int32(category))
            }
        }
        return BridgeInput(
            flags: flags(for: options),
            sources: network.links.map { UInt32($0.source) },
            targets: network.links.map { UInt32($0.target) },
            weights: network.links.map(\.weight),
            bipartiteStartID: network.bipartiteStartID.map(Int64.init) ?? -1,
            metaNodes: metaNodes,
            metaCategories: metaCategories
        )
    }

    /// The Infomap flags string for the validated options. `--silent` is
    /// unconditional (the reference Python binding does the same); a run
    /// with no output directory and no output flags never touches the
    /// filesystem. Defaults that match the core's own (flow model,
    /// Markov time 1, metadata rate 1) are still passed explicitly where
    /// harmless, and omitted where the flag's mere presence changes
    /// behavior (`--two-level`, `--regularized`, `--variable-markov-time`).
    static func flags(for options: InfomapOptions) -> String {
        var flags = [
            "--silent",
            "--seed", "\(options.seed)",
            "--num-trials", "\(options.trials)",
            "--flow-model", options.flow.rawValue,
        ]
        if options.hierarchy == .twoLevel {
            flags.append("--two-level")
        }
        if options.markovTime != 1.0 {
            flags += ["--markov-time", "\(options.markovTime)"]
        }
        if options.variableMarkovTime {
            flags.append("--variable-markov-time")
        }
        if case .bayesian(let strength) = options.regularization {
            flags += ["--regularized", "--regularization-strength", "\(strength)"]
        }
        if let metadata = options.metadata, metadata.rate != 1.0 {
            flags += ["--meta-data-rate", "\(metadata.rate)"]
        }
        return flags.joined(separator: " ")
    }

    // MARK: The C++ call and result conversion

    private nonisolated static func runCore(_ input: BridgeInput) -> Result<Partition, InfomapError> {
        var sources = cinfomap.UInt32Vector()
        var targets = cinfomap.UInt32Vector()
        var weights = cinfomap.DoubleVector()
        sources.reserve(input.sources.count)
        targets.reserve(input.targets.count)
        weights.reserve(input.weights.count)
        for value in input.sources { sources.push_back(value) }
        for value in input.targets { targets.push_back(value) }
        for value in input.weights { weights.push_back(value) }
        var metaNodes = cinfomap.UInt32Vector()
        var metaCategories = cinfomap.Int32Vector()
        for value in input.metaNodes { metaNodes.push_back(value) }
        for value in input.metaCategories { metaCategories.push_back(value) }

        let result = cinfomap.run(
            std.string(input.flags),
            sources, targets, weights,
            input.bipartiteStartID,
            metaNodes, metaCategories
        )
        guard result.ok else {
            return .failure(.engineFailure(message: String(result.errorMessage)))
        }
        return convert(result)
    }

    private nonisolated static func convert(_ result: cinfomap.RunResult) -> Result<Partition, InfomapError> {
        let isLeaf = Array(result.rowIsLeaf)
        let pathLengths = Array(result.rowPathLength)
        let pathFlat = Array(result.rowPathFlat)
        let flows = Array(result.rowFlow)
        let enterFlows = Array(result.rowEnterFlow)
        let exitFlows = Array(result.rowExitFlow)
        let nodeIDs = Array(result.rowNodeId)

        var modules: [Partition.ModulePath: Partition.Module] = [:]
        var nodePaths: [Int: Partition.ModulePath] = [:]
        var nodeFlow: [Int: Double] = [:]
        var moduleNodes: [Partition.ModulePath: [Int]] = [:]

        var offset = 0
        for row in 0..<isLeaf.count {
            let length = Int(pathLengths[row])
            let components = pathFlat[offset..<(offset + length)].map(Int.init)
            offset += length
            if isLeaf[row] == 1 {
                // The last component is the leaf's 1-based position within
                // its leaf module; the module path is everything before it.
                guard components.count >= 2 else {
                    return .failure(.engineFailure(
                        message: "unexpected tree shape: leaf node at root level (path \(components))"
                    ))
                }
                let module = Partition.ModulePath(Array(components.dropLast()))
                let node = Int(nodeIDs[row])
                nodePaths[node] = module
                nodeFlow[node] = flows[row]
                moduleNodes[module, default: []].append(node)
            } else {
                let path = Partition.ModulePath(components)
                modules[path] = Partition.Module(
                    path: path,
                    flow: flows[row],
                    enterFlow: enterFlows[row],
                    exitFlow: exitFlows[row],
                    childCount: 0,
                    nodes: []
                )
            }
        }

        // childCount = direct submodules (the spec's definition — not the
        // core's childDegree, which counts leaves too).
        for path in modules.keys {
            if let parent = path.parent {
                modules[parent]?.childCount += 1
            }
        }
        for (path, nodes) in moduleNodes {
            guard modules[path] != nil else {
                return .failure(.engineFailure(
                    message: "unexpected tree shape: leaf nodes under unreported module \(path.components)"
                ))
            }
            modules[path]?.nodes = nodes
        }

        return .success(Partition(
            codelength: result.codelength,
            oneLevelCodelength: result.oneLevelCodelength,
            relativeCodelengthSavings: result.relativeCodelengthSavings,
            numLevels: Int(result.numLevels),
            numTopModules: Int(result.numTopModules),
            numLeafModules: modules.values.count(where: { $0.childCount == 0 }),
            modules: modules,
            nodePaths: nodePaths,
            nodeFlow: nodeFlow
        ))
    }
}
