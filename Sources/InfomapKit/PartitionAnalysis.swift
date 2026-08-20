/// Pure-Swift analysis over a ``Partition`` — the quantities the map-equation
/// framework defines but the Infomap core does not export. Everything here is
/// a deterministic function of the partition (and, where stated, a cover
/// labeling); no engine calls.
///
/// Spec stage: signatures and semantics are the contract; bodies land in
/// roadmap step 4 and must be validated against hand-computed values on the
/// 16-node toy network from the map-equation-basins experiment.
public struct PartitionAnalysis: Sendable {
    public let partition: Partition

    public init(_ partition: Partition) {
        self.partition = partition
    }

    // MARK: Tunneling / similarity (arXiv:2311.04036 §9.2)

    /// Map-equation similarity `mapsim(u, v, M) = r_{u,m} · r_{m,v}`: the rate
    /// at which a walker at `u` transitions up to the smallest module
    /// containing both nodes, times the rate at which that module's index
    /// level reaches and visits `v`. Asymmetric, and defined for node pairs
    /// with **no observed link** — which is exactly the cross-basin
    /// "tunneling" case (noema §17.3).
    public func mapsim(from source: Int, to target: Int) -> Double {
        _unimplemented()
    }

    /// `d(u, v) = −log₂ mapsim(u, v, M)` in bits — the separatrix-crossing /
    /// tunneling cost used by the walk layer (noema P2.4) and cross-workstream
    /// serving (mnemosis P5).
    public func mapsimDistance(from source: Int, to target: Int) -> Double {
        _unimplemented()
    }

    // MARK: Centrality (arXiv:2311.04036 §9.1, Eq. 50)

    /// Map-equation centrality: the coding benefit the node's removal would
    /// grant the rest of its module,
    /// `λ(M, u) = −(p_m^↻ − p_u) · log₂((p_m^↻ − p_u) / p_m^↻)`.
    /// Community-aware importance — distinguishes bridges from hubs; a
    /// candidate serving-rank feature (mnemosis P5).
    public func centrality(of node: Int) -> Double {
        _unimplemented()
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
    public static func nmi(
        _ a: Partition, _ b: Partition, at depth: ComparisonDepth = .leaf
    ) -> Double {
        _unimplemented()
    }

    /// The Gate-G5 cover-agreement metric as validated in the
    /// map-equation-basins experiment (z = 40 on the site-design store):
    /// NMI between the partition (at `depth`) and an external cover labeling,
    /// against an empirical null from `permutations` random relabelings.
    ///
    /// The z-score — not raw NMI — is the gate statistic: fine partitions
    /// inflate chance NMI (null mean was 0.57 on the validation corpus).
    public static func coverAgreement(
        _ partition: Partition,
        cover: [Int: Int],
        at depth: ComparisonDepth = .leaf,
        permutations: Int = 1000,
        seed: UInt64 = 42
    ) -> CoverAgreement {
        _unimplemented()
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
        _unimplemented()
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
        /// Modal top-module count over the pre-collapse plateau, if one exists.
        public var plateauModuleCount: Int?
        /// Smallest swept strength at which the partition collapses to one
        /// module — the corpus's density margin. `nil` if it never collapses
        /// in the swept range.
        public var collapseStrength: Double?

        public init(points: [Point], plateauModuleCount: Int?, collapseStrength: Double?) {
            self.points = points
            self.plateauModuleCount = plateauModuleCount
            self.collapseStrength = collapseStrength
        }
    }

    /// Runs the sweep. Note: per iliasaz/infomap#1, regularized runs must not
    /// carry a bipartite declaration — implementations strip it (unipartite
    /// prior, conservative) and record that in the result, matching the
    /// validation experiment's method.
    public static func run(
        network: FlowNetwork,
        options: InfomapOptions,
        strengths: [Double] = [0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.5, 0.65, 0.8, 1.0],
        engine: any InfomapRunning
    ) async throws -> Result {
        _unimplemented()
    }
}

/// Spec-stage marker. Every call site is a contract awaiting roadmap step 4;
/// the marker keeps unfinished paths loud instead of silently wrong.
private func _unimplemented(
    function: StaticString = #function, file: StaticString = #file, line: UInt = #line
) -> Never {
    fatalError("InfomapKit spec stage: \(function) is not implemented yet", file: file, line: line)
}
