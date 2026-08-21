/// The result of a detection run: the nested module tree with per-module flow
/// rates, per-node assignments and visit rates, and the codelength statistics.
///
/// This is the object mnemosis persists as substrate state (it is `Codable`
/// for that reason) and the sole input to ``PartitionAnalysis`` — everything
/// downstream (mapsim, centrality, Φ derivation, stability diffs) is a pure
/// function of a `Partition`, never a second engine call.
public struct Partition: Sendable, Codable, Equatable {
    /// A module's position in the hierarchy as the sequence of child indices
    /// from the root, e.g. `[2, 1]` = second top module → its first child.
    /// Matches Infomap tree-file paths (1-based components).
    public struct ModulePath: Sendable, Codable, Hashable {
        public var components: [Int]

        public init(_ components: [Int]) {
            self.components = components
        }

        public var depth: Int { components.count }

        /// The enclosing module's path, or nil at top level.
        public var parent: ModulePath? {
            components.count > 1 ? ModulePath(Array(components.dropLast())) : nil
        }

        /// The path truncated to `depth` components (for reading the
        /// hierarchy at a chosen serving level — "the funnel").
        public func prefix(depth: Int) -> ModulePath {
            ModulePath(Array(components.prefix(depth)))
        }
    }

    /// One module of the hierarchy with the flow rates the map equation
    /// assigns it (arXiv:2311.04036 Eqs. 7–18). These three rates are the
    /// raw material for separatrix costs, mapsim, and Φ derivation — a
    /// binding that drops them is useless to the consumers.
    public struct Module: Sendable, Codable, Equatable {
        public var path: ModulePath
        /// Aggregate module flow: the sum of the visit rates of the nodes it
        /// contains at any depth — the tree-file flow column, exactly as the
        /// engine reports it. The codebook use rate `p_m^↻` (member/child
        /// rates plus exit) is derived from these fields by
        /// ``PartitionAnalysis``, not stored.
        public var flow: Double
        /// Module entry rate `q_m↷`.
        public var enterFlow: Double
        /// Module exit rate `q_m↶`.
        public var exitFlow: Double
        /// Number of direct submodules (0 for a leaf module).
        public var childCount: Int
        /// Node IDs assigned directly to this module (non-empty only for
        /// leaf modules).
        public var nodes: [Int]

        public init(
            path: ModulePath,
            flow: Double,
            enterFlow: Double,
            exitFlow: Double,
            childCount: Int,
            nodes: [Int]
        ) {
            self.path = path
            self.flow = flow
            self.enterFlow = enterFlow
            self.exitFlow = exitFlow
            self.childCount = childCount
            self.nodes = nodes
        }

        public var isLeaf: Bool { childCount == 0 }
    }

    // MARK: Codelength statistics

    /// Final two-part codelength `L(M)` in bits.
    public var codelength: Double
    /// Codelength of the one-module partition — the no-structure baseline.
    public var oneLevelCodelength: Double
    /// `1 − codelength / oneLevelCodelength`: the query-independent
    /// substrate-quality scalar (noema §17.1).
    public var relativeCodelengthSavings: Double

    // MARK: Shape

    public var numLevels: Int
    public var numTopModules: Int
    public var numLeafModules: Int

    // MARK: Storage

    /// Every module in the hierarchy, keyed by path.
    public var modules: [ModulePath: Module]
    /// Each node's leaf-module path.
    public var nodePaths: [Int: ModulePath]
    /// Each node's stationary visit rate `p_u` — required by
    /// ``PartitionAnalysis`` for centrality (Eq. 50) and mapsim (§9.2).
    public var nodeFlow: [Int: Double]

    public init(
        codelength: Double,
        oneLevelCodelength: Double,
        relativeCodelengthSavings: Double,
        numLevels: Int,
        numTopModules: Int,
        numLeafModules: Int,
        modules: [ModulePath: Module],
        nodePaths: [Int: ModulePath],
        nodeFlow: [Int: Double]
    ) {
        self.codelength = codelength
        self.oneLevelCodelength = oneLevelCodelength
        self.relativeCodelengthSavings = relativeCodelengthSavings
        self.numLevels = numLevels
        self.numTopModules = numTopModules
        self.numLeafModules = numLeafModules
        self.modules = modules
        self.nodePaths = nodePaths
        self.nodeFlow = nodeFlow
    }

    // MARK: Assignment accessors

    /// The node's full nested path, or nil for a node the run never saw.
    public func path(of node: Int) -> ModulePath? {
        nodePaths[node]
    }

    /// The node's leaf-module path.
    public func leafModule(of node: Int) -> ModulePath? {
        nodePaths[node]
    }

    /// The node's top-level module index.
    public func topModule(of node: Int) -> Int? {
        nodePaths[node]?.components.first
    }

    /// The node's module at a chosen depth (serving-level read; depth 1 =
    /// top). Returns the leaf path when the node's path is shallower.
    public func module(of node: Int, atDepth depth: Int) -> ModulePath? {
        guard let path = nodePaths[node] else { return nil }
        return path.prefix(depth: Swift.min(depth, path.depth))
    }

    /// The module at a path, with its flow rates.
    public func module(at path: ModulePath) -> Module? {
        modules[path]
    }
}
