/// Detection options, mirroring the subset of Infomap CLI/API options
/// needed for multilevel basin detection on (hyper)graphs.
///
/// Defaults: multilevel, undirected flow, no regularization, Markov time 1.
public struct InfomapOptions: Sendable, Hashable, Codable {
    /// How the engine derives flow from the input links
    /// (Infomap `--flow-model`).
    public enum FlowModel: String, Sendable, Codable {
        case undirected
        case directed
        /// Undirected flow, directed codelength.
        case undirdir
        /// Directed flow on links, undirected on teleportation.
        case outdirdir
        /// Raw directed link weights as flow, no power iteration.
        case rawdir
    }

    /// Bayesian regularization of transition rates (arXiv:2311.04036 §7,
    /// Eqs. 40–46): a Dirichlet prior that returns the one-module null when
    /// the observations cannot support finer structure.
    ///
    /// Protocol reminder: default-strength savings is
    /// *not* a valid structure metric on sparse graphs — use
    /// ``StrengthSweep`` and report the plateau partition and collapse point.
    public enum Regularization: Sendable, Hashable, Codable {
        case off
        /// `--regularized --regularization-strength <strength>`.
        case bayesian(strength: Double)

        public static var bayesianDefault: Regularization { .bayesian(strength: 1.0) }
    }

    /// Two-level flat partition vs. the full multilevel hierarchy.
    /// Consumers serve from the hierarchy (the funnel), so multilevel is
    /// the default; two-level exists for comparisons and tests.
    public enum Hierarchy: String, Sendable, Codable {
        case twoLevel
        case multilevel
    }

    /// Per-node categorical labels for the content map equation
    /// (arXiv:2311.04036 §6.1, Eq. 36) — module-label entropy against
    /// declared covers.
    public struct MetadataEncoding: Sendable, Hashable, Codable {
        /// node ID → category index.
        public var labels: [Int: Int]
        /// Metadata encoding rate η (Infomap `--meta-data-rate`, default 1).
        public var rate: Double

        public init(labels: [Int: Int], rate: Double = 1.0) {
            self.labels = labels
            self.rate = rate
        }
    }

    /// RNG seed (Infomap `--seed`). Runs with equal seed, trials, options,
    /// and network must be bit-reproducible — required for
    /// partition-stability regression.
    public var seed: UInt64
    /// Independent search trials; the best codelength wins (`--num-trials`).
    /// Real-world networks with near-tie local optima need a generous
    /// count to settle reliably — default accordingly.
    public var trials: Int
    public var hierarchy: Hierarchy
    public var flow: FlowModel
    public var regularization: Regularization
    /// Markov time scaling (`--markov-time`, §3.3): > 1 favors larger modules.
    public var markovTime: Double
    /// Local Markov-time adaptation (`--variable-markov-time`, §3.3) for
    /// density-heterogeneous networks (dense clusters vs sparse periphery).
    public var variableMarkovTime: Bool
    public var metadata: MetadataEncoding?

    public init(
        seed: UInt64 = 42,
        trials: Int = 50,
        hierarchy: Hierarchy = .multilevel,
        flow: FlowModel = .undirected,
        regularization: Regularization = .off,
        markovTime: Double = 1.0,
        variableMarkovTime: Bool = false,
        metadata: MetadataEncoding? = nil
    ) {
        self.seed = seed
        self.trials = trials
        self.hierarchy = hierarchy
        self.flow = flow
        self.regularization = regularization
        self.markovTime = markovTime
        self.variableMarkovTime = variableMarkovTime
        self.metadata = metadata
    }
}
