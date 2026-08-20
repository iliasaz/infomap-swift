# infomap-swift

Swift bindings for the [Infomap](https://github.com/mapequation/infomap) C++ core — map-equation community detection (Smiljanić et al., arXiv:2311.04036) — plus the partition-analysis utilities the map-equation framework defines but the core does not export (mapsim, map-equation centrality, partition comparison).

**Status: interface specification.** `Sources/InfomapKit/` compiles but nothing is implemented — the types and protocols are the contract, written first so the consumers can be designed against them. Implementation strategy is decided (below); code comes next.

## Why this exists

Two private projects need map-equation basins as a library, not a CLI:

- **mnemosis** Phase 5 (field layer): multilevel basin detection over the episode transition tensor, nested-partition serving (the funnel), separatrix/tunneling costs, partition-stability regression (Gate G2r extension), Gate G5 cover-agreement metrics.
- **noema** Stage P2.3–P2.4: basin detection as the primary substrate-field operation, `Φ` derived from the nested partition + flow rates, mapsim as the tunneling cost.

Both were validated empirically in `noema/experiments/map-equation-basins/` (2026-08-20) using the Python package; this repo is the production path for the Swift stack.

## Binding strategy

**Wrap the C++ core via Swift/C++ interoperability** (the MLX-Swift precedent). The Infomap core is C++14, built as a static library from a vendored submodule pin of [iliasaz/infomap](https://github.com/iliasaz/infomap) (our fork — carries the bug documented below until fixed). A thin C++-interop target (`CInfomap`) exposes the minimal engine surface; `InfomapKit` is the Swift API and never leaks C++ types.

Fallback (not plan of record): a C shim layer if C++ interop hits a wall on Linux; reimplementing the two-level objective (Eq. 11) in pure Swift is the last resort.

## Conventions (inherited from mnemosis)

- Swift 6.3+, strict concurrency, **macOS 26+ and Linux (Ubuntu 24.04)**; CI must run both.
- The engine call is blocking C++ — it runs off the cooperative pool behind an `async` surface. All result types are `Sendable` value types.
- No force unwraps; typed errors. `swift-log` for any diagnostics; never `print()`.
- Tests: Swift Testing (`@Test`/`#expect`). Golden-partition fixtures come from the Python reference implementation on synthetic networks (the planted-8-group generator from the map-equation-basins experiment) so the bindings are verified against the reference, not against themselves.

## The interface, in one look

```swift
var network = FlowNetwork(bipartiteStartID: 332)        // hyperedge×node incidence
network.addLink(from: 0, to: 400, weight: 0.42)

var options = InfomapOptions(seed: 42, trials: 50)
options.flow = .undirected
options.regularization = .off                            // see Known upstream bug

let partition = try await InfomapEngine.shared.run(network, options: options)

partition.relativeCodelengthSavings                      // substrate-quality scalar
partition.leafModule(of: 17)                             // node → leaf basin
partition.path(of: 17)                                   // node → nested module path
partition.module(at: path)?.enterFlow                    // q_m↷ — separatrix ingredients

let analysis = PartitionAnalysis(partition)
analysis.mapsimDistance(from: 17, to: 902)               // tunneling cost, −log₂ mapsim
analysis.centrality(of: 17)                              // map-equation centrality
PartitionAnalysis.nmi(partition, other)                  // stability / cover agreement
PartitionAnalysis.membershipDiff(partition, rebuilt)     // G2r alluvial regression
```

See the doc comments in `Sources/InfomapKit/` — they are the specification, including semantics, units, and the paper-equation cross-references.

## What the consumers require (the contract behind the API)

1. **Network construction**: weighted directed/undirected links over integer node IDs; bipartite start ID for hyperedge-incidence networks; per-link weights carry hyperedge-dependent node weights `γ_e(v)` (paper Eqs. 29–30).
2. **Detection options**: seed, trial count, two-level vs multilevel, flow model, Bayesian regularization with strength (paper §7), Markov time + variable Markov time (paper §3.3), per-node categorical metadata for the content map equation (paper §6.1 — Gate G5).
3. **Partition results**: codelength / one-level codelength / relative savings; the full nested module tree with **per-module flow, enter flow, and exit flow at every level** (`p_m^↻`, `q_m↷`, `q_m↶` — required for separatrix costs, `Φ` derivation, and mapsim); per-node leaf/top/at-depth assignment and full path. `Codable`, so a partition can persist as substrate state (SQLite).
4. **Derived analysis** (pure Swift over the partition — the core does not export these): mapsim and mapsim distance (paper §9.2, asymmetric, defined for unlinked pairs); map-equation centrality (paper §9.1, Eq. 50); NMI + permutation-null z (Gate G5 metric as validated at z = 40 in the experiment); membership diff between two partitions (the G2r alluvial regression artifact); regularization-strength sweep with plateau/collapse-point extraction (the sparse-graph honesty protocol — default-strength savings is *not* a valid gate metric, see the experiment §5.4).

## Known upstream bug (guarded here)

Infomap 2.15.1 `--regularized` combined with a bipartite node-type declaration either aborts ("Negative enter flow on a module…") or **silently returns a degenerate over-fragmented partition**. Documented with synthetic repro in [iliasaz/infomap#1](https://github.com/iliasaz/infomap/issues/1). Until fixed in the vendored pin, `InfomapEngine.run` must throw `InfomapError.unsupportedConfiguration` for `regularization != .off && network.bipartiteStartID != nil` rather than forward the call.

## Roadmap

1. ✅ Interface specification (this commit).
2. Vendor the fork as a submodule; `CInfomap` C++-interop target; make `swift build` produce the static core on macOS + Linux.
3. Implement `InfomapEngine` over the core; golden-partition parity tests vs the Python reference.
4. Implement `PartitionAnalysis` (pure Swift; testable against hand-computed values on the toy network).
5. CI (macOS 26 runner + `swift:6.3-noble` container), then adopt from mnemosis Phase 5.
