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
    /// Spec-stage placeholder: the binding is not implemented yet
    /// (roadmap step 3). Removed when the C++ target lands.
    case notImplemented
}

/// The one operation consumers depend on. Kept as a protocol so mnemosis
/// tests can substitute a fixture engine (golden partitions from the Python
/// reference implementation) without linking the C++ core.
public protocol InfomapRunning: Sendable {
    /// Runs map-equation minimization and returns the full partition.
    ///
    /// Implementation contract:
    /// - The C++ call is blocking; it must run off the Swift cooperative
    ///   pool. The core offers no cancellation hook — callers should treat
    ///   a run as non-cancellable and size inputs accordingly (the 369K-link
    ///   validation corpus ran in ~40 s).
    /// - Equal `(network, options)` including seed ⇒ identical `Partition`
    ///   (bit-reproducibility is what makes the G2r stability regression
    ///   meaningful).
    /// - Must throw ``InfomapError/unsupportedConfiguration(reason:)`` for
    ///   `options.regularization != .off && network.bipartiteStartID != nil`
    ///   while iliasaz/infomap#1 is unfixed in the vendored pin.
    func run(_ network: FlowNetwork, options: InfomapOptions) async throws -> Partition
}

/// The production engine over the vendored Infomap C++ core.
///
/// An actor: the core is not documented thread-safe, so runs serialize here;
/// parallel sweeps (e.g. ``StrengthSweep``) create multiple engines.
public actor InfomapEngine: InfomapRunning {
    public static let shared = InfomapEngine()

    public init() {}

    public func run(_ network: FlowNetwork, options: InfomapOptions) async throws -> Partition {
        try Self.validate(network: network, options: options)
        // Roadmap step 3: bridge to the CInfomap C++-interop target.
        throw InfomapError.notImplemented
    }

    /// Pre-flight checks — implemented at spec stage because the guard *is*
    /// part of the contract (see iliasaz/infomap#1).
    static func validate(network: FlowNetwork, options: InfomapOptions) throws {
        if network.links.isEmpty {
            throw InfomapError.invalidNetwork(reason: "network has no links")
        }
        if let bad = network.links.first(where: { !($0.weight > 0) || !$0.weight.isFinite }) {
            throw InfomapError.invalidNetwork(
                reason: "link \(bad.source)→\(bad.target) has non-positive or non-finite weight \(bad.weight)"
            )
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
    }
}
