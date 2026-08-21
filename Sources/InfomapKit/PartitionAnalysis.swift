import Foundation

/// Pure-Swift analysis over a ``Partition`` — the quantities the map-equation
/// framework defines but the Infomap core does not export. Everything here is
/// a deterministic function of the partition (and, where stated, a cover
/// labeling); no engine calls.
///
/// Numeric conventions: NMI follows the map-equation-basins experiment's
/// reference implementation (natural-log mutual information, arithmetic-mean
/// normalization, shared nodes only); permutation nulls use sample (n−1)
/// standard deviation and a SplitMix64 shuffle so results are reproducible
/// across platforms (Swift and Python nulls agree statistically, not bitwise).
public struct PartitionAnalysis: Sendable {
    public let partition: Partition

    /// Codebook use rate `p_m^↻` per module: exit flow + Σ child enter flows
    /// + Σ directly-assigned node visit rates (for a leaf module that last
    /// term is the module flow). Precomputed once — mapsim and centrality
    /// are both quotients of these rates.
    private let codebookUseRate: [Partition.ModulePath: Double]
    /// Use rate of the root (index) codebook: Σ top-module enter flows.
    private let rootUseRate: Double

    public init(_ partition: Partition) {
        self.partition = partition

        var childEnter: [Partition.ModulePath: Double] = [:]
        var rootEnter = 0.0
        // Sorted iteration: dictionary order is hash-seeded per process, and
        // float accumulation is order-sensitive — sorting keeps the rates
        // (hence mapsim) bit-stable across processes analyzing the same
        // persisted partition, matching the nmi implementation's discipline.
        let orderedModules = partition.modules.sorted {
            $0.key.components.lexicographicallyPrecedes($1.key.components)
        }
        for (path, module) in orderedModules {
            if let parent = path.parent {
                childEnter[parent, default: 0] += module.enterFlow
            } else {
                rootEnter += module.enterFlow
            }
        }
        var rates: [Partition.ModulePath: Double] = Dictionary(minimumCapacity: partition.modules.count)
        for (path, module) in orderedModules {
            let nodeRates = module.nodes.reduce(0.0) { $0 + (partition.nodeFlow[$1] ?? 0) }
            rates[path] = module.exitFlow + childEnter[path, default: 0] + nodeRates
        }
        self.codebookUseRate = rates
        self.rootUseRate = rootEnter
    }

    // MARK: Tunneling / similarity (arXiv:2311.04036 §9.2)

    /// Map-equation similarity `mapsim(u, v, M) = r_{u,m} · r_{m,v}`: the rate
    /// at which a walker at `u` transitions up to the smallest module
    /// containing both nodes, times the rate at which that module's index
    /// level reaches and visits `v`. Asymmetric, and defined for node pairs
    /// with **no observed link** — which is exactly the cross-basin
    /// "tunneling" case (noema §17.3).
    ///
    /// Concretely: ascending steps out of module `m` contribute
    /// `q_m↶ / p_m^↻`, descending steps into module `c` from its parent
    /// contribute `q_c↷ / p_parent^↻`, and the final visit contributes
    /// `p_v / p_leaf(v)^↻`. Returns 0 — never NaN — for nodes the partition
    /// never saw and whenever any step on the walk has zero rate
    /// (disconnected components have zero enter/exit flow between them;
    /// bipartite feature nodes report zero visit rate); `mapsimDistance` is
    /// then +∞.
    public func mapsim(from source: Int, to target: Int) -> Double {
        guard
            let sourceModule = partition.nodePaths[source],
            let targetModule = partition.nodePaths[target],
            let targetFlow = partition.nodeFlow[target]
        else { return 0 }

        let shared = commonPrefixLength(sourceModule, targetModule)
        var rate = 1.0

        // Ascend from the source's leaf module to the smallest common module.
        var m = sourceModule
        while m.depth > shared {
            let use = useRate(of: m)
            let exit = module(m).exitFlow
            guard use > 0, exit > 0 else { return 0 }
            rate *= exit / use
            guard let parent = m.parent else { break }
            m = parent
        }
        // Descend along the target's chain from just below the common module.
        if targetModule.depth > shared {
            for depth in (shared + 1)...targetModule.depth {
                let child = targetModule.prefix(depth: depth)
                let use = useRate(above: child)
                let enter = module(child).enterFlow
                guard use > 0, enter > 0 else { return 0 }
                rate *= enter / use
            }
        }
        // Visit the target within its leaf-module codebook.
        let leafUse = useRate(of: targetModule)
        guard leafUse > 0, targetFlow > 0 else { return 0 }
        rate *= targetFlow / leafUse
        return rate
    }

    /// `d(u, v) = −log₂ mapsim(u, v, M)` in bits — the separatrix-crossing /
    /// tunneling cost used by the walk layer (noema P2.4) and cross-workstream
    /// serving (mnemosis P5). `+∞` when the walker cannot reach `v` at all
    /// (zero rate or unknown node).
    public func mapsimDistance(from source: Int, to target: Int) -> Double {
        let similarity = mapsim(from: source, to: target)
        guard similarity > 0 else { return .infinity }
        return -log2(similarity)
    }

    // MARK: Centrality (arXiv:2311.04036 §9.1, Eq. 50)

    /// Map-equation centrality: the coding benefit the node's removal would
    /// grant the rest of its module,
    /// `λ(M, u) = −(p_m^↻ − p_u) · log₂((p_m^↻ − p_u) / p_m^↻)`,
    /// with `p_m^↻` the use rate of the node's leaf-module codebook.
    /// Community-aware importance — distinguishes bridges from hubs; a
    /// candidate serving-rank feature (mnemosis P5). 0 for unknown nodes.
    public func centrality(of node: Int) -> Double {
        guard
            let leaf = partition.nodePaths[node],
            let nodeFlow = partition.nodeFlow[node]
        else { return 0 }
        let use = useRate(of: leaf)
        let rest = use - nodeFlow
        guard use > 0, rest > 0 else { return 0 }
        return -rest * log2(rest / use)
    }

    // MARK: Rate helpers

    private func module(_ path: Partition.ModulePath) -> Partition.Module {
        partition.modules[path] ?? .init(path: path, flow: 0, enterFlow: 0, exitFlow: 0, childCount: 0, nodes: [])
    }

    private func useRate(of path: Partition.ModulePath) -> Double {
        codebookUseRate[path] ?? 0
    }

    /// The use rate of the codebook a walker chooses `path`'s enter word
    /// from — the parent module's, or the root index codebook at depth 1.
    private func useRate(above path: Partition.ModulePath) -> Double {
        if let parent = path.parent { return useRate(of: parent) }
        return rootUseRate
    }

    private func commonPrefixLength(_ a: Partition.ModulePath, _ b: Partition.ModulePath) -> Int {
        var count = 0
        while count < a.components.count, count < b.components.count,
              a.components[count] == b.components[count] {
            count += 1
        }
        return count
    }

    // MARK: Partition agreement and stability

    /// Which level of both partitions a comparison reads.
    public enum ComparisonDepth: Sendable, Hashable {
        case top
        case leaf
        case depth(Int)
    }

    /// Normalized mutual information between two partitions over their shared
    /// nodes. Used for solution-landscape checks (multi-seed agreement)
    /// and cross-method comparisons.
    ///
    /// Reference-implementation semantics (map-equation-basins experiment):
    /// natural-log MI normalized by the arithmetic mean of the two label
    /// entropies; 0 when there are no shared nodes or both labelings are
    /// trivial (zero entropy).
    public static func nmi(
        _ a: Partition, _ b: Partition, at depth: ComparisonDepth = .leaf
    ) -> Double {
        nmi(labels(of: a, at: depth), labels(of: b, at: depth))
    }

    /// The Gate-G5 cover-agreement metric as validated in the
    /// map-equation-basins experiment (z = 40 on the site-design store):
    /// NMI between the partition (at `depth`) and an external cover labeling,
    /// against an empirical null from `permutations` random relabelings.
    ///
    /// The z-score — not raw NMI — is the gate statistic: fine partitions
    /// inflate chance NMI (null mean was 0.57 on the validation corpus).
    /// The null shuffle is a seeded SplitMix64 Fisher–Yates, bit-reproducible
    /// across runs and platforms; std is the sample (n−1) deviation and
    /// `z = +∞` when the null is degenerate (std 0), matching the reference.
    public static func coverAgreement(
        _ partition: Partition,
        cover: [Int: Int],
        at depth: ComparisonDepth = .leaf,
        permutations: Int = 1000,
        seed: UInt64 = 42
    ) -> CoverAgreement {
        let moduleLabels = labels(of: partition, at: depth)
        let sharedNodes = moduleLabels.keys.filter { cover[$0] != nil }.sorted()
        let observed = nmi(
            moduleLabels,
            cover.reduce(into: [Int: AnyHashable]()) { $0[$1.key] = AnyHashable($1.value) }
        )
        guard !sharedNodes.isEmpty, permutations > 0 else {
            return CoverAgreement(nmi: observed, nullMean: 0, nullStd: 0, z: .infinity, comparedNodes: sharedNodes.count)
        }

        let sharedModuleLabels = moduleLabels.filter { cover[$0.key] != nil }
        var shuffled = sharedNodes.map { cover[$0]! }
        var rng = SplitMix64(seed: seed)
        var null: [Double] = []
        null.reserveCapacity(permutations)
        for _ in 0..<permutations {
            rng.fisherYatesShuffle(&shuffled)
            var permuted: [Int: AnyHashable] = Dictionary(minimumCapacity: sharedNodes.count)
            for (node, label) in zip(sharedNodes, shuffled) { permuted[node] = AnyHashable(label) }
            null.append(nmi(sharedModuleLabels, permuted))
        }
        let mean = null.reduce(0, +) / Double(null.count)
        let variance = null.count > 1
            ? null.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(null.count - 1)
            : 0
        let std = variance.squareRoot()
        let z = std > 0 ? (observed - mean) / std : .infinity
        return CoverAgreement(nmi: observed, nullMean: mean, nullStd: std, z: z, comparedNodes: sharedNodes.count)
    }

    public struct CoverAgreement: Sendable, Codable, Equatable {
        public var nmi: Double
        public var nullMean: Double
        public var nullStd: Double
        public var z: Double
        public var comparedNodes: Int

        public init(nmi: Double, nullMean: Double, nullStd: Double, z: Double, comparedNodes: Int) {
            self.nmi = nmi
            self.nullMean = nullMean
            self.nullStd = nullStd
            self.z = z
            self.comparedNodes = comparedNodes
        }
    }

    /// Node-level membership diff between two partitions of the same corpus —
    /// the alluvial-style regression artifact that extends Gate G2r into the
    /// field layer: an unchanged-corpus rebuild must produce an **empty**
    /// diff; a one-row change must perturb one basin's membership, visibly.
    public static func membershipDiff(_ old: Partition, _ new: Partition) -> MembershipDiff {
        var moved: [Int: MembershipDiff.Move] = [:]
        var onlyInOld: Set<Int> = []
        var onlyInNew: Set<Int> = []
        var stableCount = 0
        for (node, oldPath) in old.nodePaths {
            guard let newPath = new.nodePaths[node] else {
                onlyInOld.insert(node)
                continue
            }
            if oldPath == newPath {
                stableCount += 1
            } else {
                moved[node] = .init(from: oldPath, to: newPath)
            }
        }
        for node in new.nodePaths.keys where old.nodePaths[node] == nil {
            onlyInNew.insert(node)
        }
        return MembershipDiff(moved: moved, onlyInOld: onlyInOld, onlyInNew: onlyInNew, stableCount: stableCount)
    }

    public struct MembershipDiff: Sendable, Codable, Equatable {
        /// Nodes whose leaf-module assignment changed, with both paths.
        public var moved: [Int: Move]
        /// Nodes present in only one of the partitions.
        public var onlyInOld: Set<Int>
        public var onlyInNew: Set<Int>
        /// Count of nodes with unchanged assignment.
        public var stableCount: Int

        public struct Move: Sendable, Codable, Equatable {
            public var from: Partition.ModulePath
            public var to: Partition.ModulePath

            public init(from: Partition.ModulePath, to: Partition.ModulePath) {
                self.from = from
                self.to = to
            }
        }

        public init(
            moved: [Int: Move],
            onlyInOld: Set<Int>,
            onlyInNew: Set<Int>,
            stableCount: Int
        ) {
            self.moved = moved
            self.onlyInOld = onlyInOld
            self.onlyInNew = onlyInNew
            self.stableCount = stableCount
        }

        public var isEmpty: Bool {
            moved.isEmpty && onlyInOld.isEmpty && onlyInNew.isEmpty
        }
    }

    // MARK: Label extraction and NMI internals

    static func labels(of partition: Partition, at depth: ComparisonDepth) -> [Int: AnyHashable] {
        partition.nodePaths.mapValues { path in
            switch depth {
            case .leaf:
                return AnyHashable(path)
            case .top:
                return AnyHashable(path.prefix(depth: 1))
            case .depth(let d):
                return AnyHashable(path.prefix(depth: Swift.min(Swift.max(d, 1), path.depth)))
            }
        }
    }

    /// NMI over the keys shared by both labelings; deterministic summation
    /// order (sorted keys/labels) so results are bit-stable across processes.
    static func nmi(_ a: [Int: AnyHashable], _ b: [Int: AnyHashable]) -> Double {
        let keys = a.keys.filter { b[$0] != nil }.sorted()
        let n = Double(keys.count)
        guard n > 0 else { return 0 }

        // Densify labels to stable integer indices in first-appearance order.
        var aIndex: [AnyHashable: Int] = [:]
        var bIndex: [AnyHashable: Int] = [:]
        var countA: [Int: Int] = [:]
        var countB: [Int: Int] = [:]
        var countAB: [Pair: Int] = [:]
        for key in keys {
            let la = aIndex.index(for: a[key]!)
            let lb = bIndex.index(for: b[key]!)
            countA[la, default: 0] += 1
            countB[lb, default: 0] += 1
            countAB[Pair(la, lb), default: 0] += 1
        }

        func entropy(_ counts: [Int: Int]) -> Double {
            counts.keys.sorted().reduce(0.0) { acc, label in
                let p = Double(counts[label]!) / n
                return acc - p * log(p)
            }
        }
        let ha = entropy(countA)
        let hb = entropy(countB)
        let mi = countAB.keys.sorted().reduce(0.0) { acc, pair in
            let joint = Double(countAB[pair]!) / n
            let pa = Double(countA[pair.a]!) / n
            let pb = Double(countB[pair.b]!) / n
            return acc + joint * log(joint / (pa * pb))
        }
        let denom = (ha + hb) / 2
        return denom > 0 ? mi / denom : 0
    }

    private struct Pair: Hashable, Comparable {
        var a: Int
        var b: Int

        init(_ a: Int, _ b: Int) {
            self.a = a
            self.b = b
        }

        static func < (lhs: Pair, rhs: Pair) -> Bool {
            (lhs.a, lhs.b) < (rhs.a, rhs.b)
        }
    }
}

extension [AnyHashable: Int] {
    fileprivate mutating func index(for label: AnyHashable) -> Int {
        if let existing = self[label] { return existing }
        let next = count
        self[label] = next
        return next
    }
}

/// The sparse-graph honesty protocol (map-equation-basins experiment §5.4;
/// mnemosis P5): sweep the Bayesian regularization strength, report the
/// plateau partition and the collapse point. Default-strength regularized
/// savings is **never** a gate metric — it nulls out on graphs sparser than
/// the prior's ER-connectivity assumption, which both validation corpora were.
public struct StrengthSweep: Sendable {
    public struct Point: Sendable, Codable, Equatable {
        public var strength: Double
        public var topModules: Int
        public var leafModules: Int
        public var relativeSavings: Double

        public init(strength: Double, topModules: Int, leafModules: Int, relativeSavings: Double) {
            self.strength = strength
            self.topModules = topModules
            self.leafModules = leafModules
            self.relativeSavings = relativeSavings
        }
    }

    public struct Result: Sendable, Codable, Equatable {
        public var points: [Point]
        /// Modal top-module count over the structured (topModules > 1)
        /// points, if any exist. A transient one-module point mid-sweep
        /// (near-tie search noise at low trial counts) does not truncate
        /// the plateau statistic.
        public var plateauModuleCount: Int?
        /// Smallest swept strength at which the partition collapses to one
        /// module *and stays collapsed* through the rest of the swept range
        /// — the corpus's density margin. `nil` if the sweep ends with
        /// structure; transient mid-sweep one-module points don't count.
        public var collapseStrength: Double?
        /// True when the input network carried a bipartite declaration that
        /// the sweep stripped. The strip is methodological: it matches the
        /// validation experiment's unipartite-prior protocol, keeping
        /// plateau and collapse points comparable to its baselines. (It
        /// began as the iliasaz/infomap#1 workaround; the engine itself now
        /// supports regularized bipartite runs — loop it directly to sweep
        /// under the bipartite prior.)
        public var strippedBipartiteDeclaration: Bool

        public init(
            points: [Point],
            plateauModuleCount: Int?,
            collapseStrength: Double?,
            strippedBipartiteDeclaration: Bool = false
        ) {
            self.points = points
            self.plateauModuleCount = plateauModuleCount
            self.collapseStrength = collapseStrength
            self.strippedBipartiteDeclaration = strippedBipartiteDeclaration
        }
    }

    /// Runs the sweep, ascending in strength, on the unipartite view of the
    /// network: a bipartite declaration is stripped (and recorded in the
    /// result) so plateau/collapse points stay comparable to the validation
    /// experiment's unipartite-prior baselines. The engine itself supports
    /// regularized bipartite runs (iliasaz/infomap#1 is fixed in the
    /// vendored pin) — call it directly to sweep under the bipartite prior.
    public static func run(
        network: FlowNetwork,
        options: InfomapOptions,
        strengths: [Double] = [0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.5, 0.65, 0.8, 1.0],
        engine: any InfomapRunning
    ) async throws -> Result {
        var unipartite = network
        let stripped = unipartite.bipartiteStartID != nil
        unipartite.bipartiteStartID = nil

        var points: [Point] = []
        for strength in strengths.sorted() {
            // The safe point between runs: a cancelled sweep stops here
            // rather than burning the remaining strengths' full C++ runs.
            try Task.checkCancellation()
            var swept = options
            swept.regularization = .bayesian(strength: strength)
            let partition = try await engine.run(unipartite, options: swept)
            points.append(Point(
                strength: strength,
                topModules: partition.numTopModules,
                leafModules: partition.numLeafModules,
                relativeSavings: partition.relativeCodelengthSavings
            ))
        }

        // Collapse = entered the one-module regime and stayed there through
        // the end of the sweep. A transient one-module point mid-sweep is
        // near-tie search noise, not the density margin.
        let collapseStrength: Double?
        if let lastStructured = points.lastIndex(where: { $0.topModules > 1 }) {
            collapseStrength = lastStructured + 1 < points.count
                ? points[lastStructured + 1].strength
                : nil
        } else {
            collapseStrength = points.first?.strength
        }
        let plateau = points.filter { $0.topModules > 1 }
        var plateauModuleCount: Int?
        if !plateau.isEmpty {
            // Modal count; ties resolve toward the value seen nearest the
            // collapse point (the settled plateau, not an early transient).
            var frequency: [Int: (count: Int, lastIndex: Int)] = [:]
            for (index, point) in plateau.enumerated() {
                let entry = frequency[point.topModules] ?? (0, 0)
                frequency[point.topModules] = (entry.count + 1, index)
            }
            plateauModuleCount = frequency.max { lhs, rhs in
                (lhs.value.count, lhs.value.lastIndex) < (rhs.value.count, rhs.value.lastIndex)
            }?.key
        }
        return Result(
            points: points,
            plateauModuleCount: plateauModuleCount,
            collapseStrength: collapseStrength,
            strippedBipartiteDeclaration: stripped
        )
    }
}

/// Seeded SplitMix64 — deterministic across platforms and Swift releases,
/// unlike `SystemRandomNumberGenerator` (used for the permutation nulls).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Explicit Fisher–Yates (multiply-shift bounding) — the shuffle sequence
    /// is pinned here rather than inherited from the stdlib's
    /// `shuffle(using:)`, whose draw pattern is not a stability guarantee.
    mutating func fisherYatesShuffle<T>(_ elements: inout [T]) {
        guard elements.count > 1 else { return }
        for i in stride(from: elements.count - 1, through: 1, by: -1) {
            let bound = UInt64(i + 1)
            let j = Int(next().multipliedFullWidth(by: bound).high)
            elements.swapAt(i, j)
        }
    }
}
