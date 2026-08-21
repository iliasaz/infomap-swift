/// A weighted network handed to the Infomap engine as the flow model's substrate.
///
/// Node identifiers are caller-assigned non-negative integers; the engine never
/// renumbers them, so consumers can use stable row IDs (episode IDs, entity IDs)
/// directly and read them back out of the resulting ``Partition``.
///
/// ## Bipartite / hypergraph-incidence networks
///
/// The primary consumers build hyperedge-incidence networks: hyperedges
/// (episodes/events) as primary nodes `0..<bipartiteStartID`, vertices
/// (entities) as feature nodes `>= bipartiteStartID`, one link per incidence.
/// Per-link weights carry the hyperedge-dependent node weights `γ_e(v)` of the
/// hypergraph random walk (arXiv:2311.04036 Eqs. 29–30) — e.g. a hub penalty
/// `1/log2(1 + deg(entity))` or typed-role weights.
public struct FlowNetwork: Sendable, Hashable {
    /// One weighted link. For `FlowModel.undirected` the direction is ignored.
    public struct Link: Sendable, Hashable {
        public var source: Int
        public var target: Int
        public var weight: Double

        public init(source: Int, target: Int, weight: Double = 1.0) {
            self.source = source
            self.target = target
            self.weight = weight
        }
    }

    /// All links added so far, in insertion order (order is irrelevant to the
    /// engine but kept deterministic for reproducibility of serialized inputs).
    public private(set) var links: [Link] = []

    /// When non-nil, node IDs `>= bipartiteStartID` are the second (feature)
    /// node type and the engine runs in bipartite mode.
    ///
    /// Combining a bipartite declaration with Bayesian regularization is
    /// supported: the vendored pin carries the iliasaz/infomap#1 fix
    /// (regularized flow computed on the bipartite primary projection).
    public var bipartiteStartID: Int?

    /// Optional display names for nodes, used only in diagnostics and exports.
    public var names: [Int: String] = [:]

    public init(bipartiteStartID: Int? = nil) {
        self.bipartiteStartID = bipartiteStartID
    }

    /// Appends a weighted link. Weights must be positive and finite.
    public mutating func addLink(from source: Int, to target: Int, weight: Double = 1.0) {
        links.append(Link(source: source, target: target, weight: weight))
    }

    /// Convenience for hypergraph incidence: `hyperedge` must be a primary node
    /// (`< bipartiteStartID`) and `vertex` a feature node (`>= bipartiteStartID`).
    /// The weight is the hyperedge-dependent node weight `γ_e(v)`.
    public mutating func addIncidence(hyperedge: Int, vertex: Int, weight: Double = 1.0) {
        addLink(from: hyperedge, to: vertex, weight: weight)
    }

    /// The set of node IDs referenced by at least one link.
    public var nodeIDs: Set<Int> {
        var ids = Set<Int>(minimumCapacity: links.count)
        for link in links {
            ids.insert(link.source)
            ids.insert(link.target)
        }
        return ids
    }
}
