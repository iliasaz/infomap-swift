# infomap-swift

Swift bindings for the [Infomap](https://github.com/mapequation/infomap) C++ core — map-equation community detection (Smiljanić et al., arXiv:2311.04036) — plus the partition-analysis utilities the map-equation framework defines but the core does not export (mapsim, map-equation centrality, partition comparison).

**Status: implemented.** Engine bindings over the vendored C++ core (roadmap steps 2–3), the partition-analysis layer (step 4), and macOS + Linux CI (step 5) are in place; `swift test` verifies golden parity with the reference Python implementation on both platforms. The doc comments in `Sources/InfomapKit/` remain the interface specification.

## Why this exists

Two private projects need map-equation basins as a library, not a CLI:

- **mnemosis** Phase 5 (field layer): multilevel basin detection over the episode transition tensor, nested-partition serving (the funnel), separatrix/tunneling costs, partition-stability regression (Gate G2r extension), Gate G5 cover-agreement metrics.
- **noema** Stage P2.3–P2.4: basin detection as the primary substrate-field operation, `Φ` derived from the nested partition + flow rates, mapsim as the tunneling cost.

Both were validated empirically in `noema/experiments/map-equation-basins/` (2026-08-20) using the Python package; this repo is the production path for the Swift stack.

## Binding strategy

**Wrap the C++ core via Swift/C++ interoperability** (the MLX-Swift precedent). The Infomap core is built as a static library from a vendored submodule pin of [iliasaz/infomap](https://github.com/iliasaz/infomap) — our fork, currently pinned to the `fix/regularized-bipartite-negative-enter-flow` branch, which carries the iliasaz/infomap#1 fix (see below). A thin C++-interop target (`CInfomap`) exposes the minimal engine surface; `InfomapKit` is the Swift API and never leaks C++ types.

Fallback (not plan of record): a C shim layer if C++ interop hits a wall on Linux; reimplementing the two-level objective (Eq. 11) in pure Swift is the last resort.

## Building

```sh
git clone --recurse-submodules https://github.com/iliasaz/infomap-swift.git
# in an existing clone: git submodule update --init
swift test    # macOS 26+, or Linux via the swift:6.3-noble image
```

The core builds from source inside SwiftPM — `InfomapCore` (vendored sources) → `CInfomap` (thin C++ bridge; the only target that includes Infomap headers) → `InfomapKit` (Swift API) — no external Infomap installation. SwiftPM requires every dependent of an interop-enabled target to enable interop too, so consumers add to their own target:

```swift
.target(name: "MyTarget", dependencies: ["InfomapKit"],
        swiftSettings: [.interoperabilityMode(.Cxx)])
```

Golden fixtures regenerate with `python3 scripts/generate_golden_fixtures.py` (needs pip `infomap` 2.15.1, the reference implementation).

## Quick start

```swift
import InfomapKit

// Two triangles joined by one bridge link — the smallest network with
// obvious community structure.
var network = FlowNetwork()
for (a, b) in [(0, 1), (0, 2), (1, 2), (3, 4), (3, 5), (4, 5), (2, 3)] {
    network.addLink(from: a, to: b)
}

let partition = try await InfomapEngine.shared.run(network, options: InfomapOptions())
print(partition.numTopModules)                       // 2
print(partition.topModule(of: 0)!)                   // 1
print(partition.relativeCodelengthSavings)           // ~0.092

let analysis = PartitionAnalysis(partition)
print(analysis.mapsimDistance(from: 0, to: 5))       // cross-module tunneling cost, bits
```

Runnable, commented examples live in [`examples/`](examples/) — simple detection, bipartite hypergraph basins with hub-penalty weights, the content map equation (metadata), partition comparison (NMI / membership diff / cover agreement), and the regularization strength sweep:

```sh
swift run infomap-example
```

## Conventions (inherited from mnemosis)

- Swift 6.3+, strict concurrency, **macOS 26+ and Linux (Ubuntu 24.04)**; CI must run both.
- The engine call is blocking C++ — it runs off the cooperative pool behind an `async` surface. All result types are `Sendable` value types.
- No force unwraps; typed errors. `swift-log` for any diagnostics; never `print()`.
- Tests: Swift Testing (`@Test`/`#expect`). Golden-partition fixtures come from the Python reference implementation on synthetic networks (a planted-8-group generator built to the map-equation-basins experiment's method) so the bindings are verified against the reference, not against themselves.
- Determinism: equal `(network, options)` including seed reproduces bit-identical partitions on a given platform/build. Across platforms, low trial counts can settle in different near-tie local optima (observed on the two-level planted-8 fixture at 10 trials: macOS and Linux picked different flat solutions) — fixtures pin trial counts high enough that every platform reaches the settled optimum.

## The interface, in one look

```swift
var network = FlowNetwork(bipartiteStartID: 332)        // hyperedge×node incidence
network.addLink(from: 0, to: 400, weight: 0.42)

var options = InfomapOptions(seed: 42, trials: 50)
options.flow = .undirected
options.regularization = .off                            // or .bayesian(strength:)

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

## Upstream bug, fixed in the vendored pin

Infomap 2.15.1 `--regularized` combined with a bipartite node-type declaration either aborts ("Negative enter flow on a module…") or **silently returns a degenerate over-fragmented partition** — documented with synthetic repro in [iliasaz/infomap#1](https://github.com/iliasaz/infomap/issues/1). The vendored pin now tracks the fork's `fix/regularized-bipartite-negative-enter-flow` branch (`0853262c`: regularized flow computed on the bipartite primary projection), so the engine's original guard is lifted and the combination is supported. `RegularizedBipartiteTests` pins the two failure modes (abort-class small networks, degeneracy-class larger ones); the pip reference implementation still carries the bug, so that coverage is property-based rather than golden parity. `StrengthSweep` accordingly runs networks **as given**, bipartite declarations included — the map-equation-basins experiment's pre-registered method, which its §5.4 amendment had to abandon because of this bug. One re-baselining caveat: the experiment's *recorded* plateau/collapse numbers were measured under the amendment's unipartite prior, and the fixed core prices the prior over the bipartite primary projection (`λ = ln N_L / N_L`), so sweeps over bipartite networks are not comparable to those recorded values — re-measure before using them as gate baselines.

## Roadmap

1. ✅ Interface specification.
2. ✅ Vendored the fork as a submodule (`vendor/infomap`, pin `1434744d` = 2.15.1); `swift build` compiles the core on macOS + Linux.
3. ✅ `InfomapEngine` over the core; golden-partition parity vs the Python reference (codelengths, flows, and structure to 1e-9 on both platforms).
4. ✅ `PartitionAnalysis` (pure Swift; validated against hand-computed values).
5. ✅ CI (macOS 26 runner + `swift:6.3-noble` container).
6. Adopt from mnemosis Phase 5 / noema P2.3.
