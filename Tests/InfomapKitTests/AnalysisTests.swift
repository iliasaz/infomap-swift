import Foundation
import Testing
@testable import InfomapKit

/// PartitionAnalysis against hand-computed values on small partitions — the
/// roadmap-step-4 contract: every quantity checked against the formula
/// evaluated by hand, never against the implementation itself.
@Suite struct AnalysisTests {
    /// Two-level partition: leaf modules [1] = {0, 1}, [2] = {2, 3}.
    /// Codebook use rates: r[1] = 0.10 + 0.55 = 0.65, r[2] = 0.10 + 0.45
    /// = 0.55, root = 0.10 + 0.10 = 0.20.
    func twoLevelPartition() -> Partition {
        let m1 = Partition.ModulePath([1])
        let m2 = Partition.ModulePath([2])
        return Partition(
            codelength: 1.8, oneLevelCodelength: 2.0, relativeCodelengthSavings: 0.1,
            numLevels: 2, numTopModules: 2, numLeafModules: 2,
            modules: [
                m1: .init(path: m1, flow: 0.55, enterFlow: 0.10, exitFlow: 0.10, childCount: 0, nodes: [0, 1]),
                m2: .init(path: m2, flow: 0.45, enterFlow: 0.10, exitFlow: 0.10, childCount: 0, nodes: [2, 3]),
            ],
            nodePaths: [0: m1, 1: m1, 2: m2, 3: m2],
            nodeFlow: [0: 0.30, 1: 0.25, 2: 0.25, 3: 0.20]
        )
    }

    /// Three-level partition: top module [1] with leaf submodules
    /// [1,1] = {0, 1} and [1,2] = {2}; top leaf module [2] = {3, 4}.
    /// Use rates: r[1,1] = 0.05 + 0.35 = 0.40; r[1,2] = 0.08 + 0.15 = 0.23;
    /// r[1] = 0.10 + (0.06 + 0.07) = 0.23; r[2] = 0.12 + 0.50 = 0.62;
    /// root = 0.12 + 0.10 = 0.22.
    func threeLevelPartition() -> Partition {
        let m1 = Partition.ModulePath([1])
        let m11 = Partition.ModulePath([1, 1])
        let m12 = Partition.ModulePath([1, 2])
        let m2 = Partition.ModulePath([2])
        return Partition(
            codelength: 2.1, oneLevelCodelength: 2.5, relativeCodelengthSavings: 0.16,
            numLevels: 3, numTopModules: 2, numLeafModules: 3,
            modules: [
                m1: .init(path: m1, flow: 0.50, enterFlow: 0.12, exitFlow: 0.10, childCount: 2, nodes: []),
                m11: .init(path: m11, flow: 0.35, enterFlow: 0.06, exitFlow: 0.05, childCount: 0, nodes: [0, 1]),
                m12: .init(path: m12, flow: 0.15, enterFlow: 0.07, exitFlow: 0.08, childCount: 0, nodes: [2]),
                m2: .init(path: m2, flow: 0.50, enterFlow: 0.10, exitFlow: 0.12, childCount: 0, nodes: [3, 4]),
            ],
            nodePaths: [0: m11, 1: m11, 2: m12, 3: m2, 4: m2],
            nodeFlow: [0: 0.20, 1: 0.15, 2: 0.15, 3: 0.30, 4: 0.20]
        )
    }

    @Test func mapsimWithinLeafModule() {
        let analysis = PartitionAnalysis(twoLevelPartition())
        // Same leaf module: p_v / r_m.
        #expect(abs(analysis.mapsim(from: 0, to: 1) - 0.25 / 0.65) < 1e-12)
        #expect(abs(analysis.mapsim(from: 1, to: 0) - 0.30 / 0.65) < 1e-12)
    }

    @Test func mapsimAcrossTopModules() {
        let analysis = PartitionAnalysis(twoLevelPartition())
        // Exit [1] (0.10/0.65) → enter [2] from root (0.10/0.20) → visit 2
        // (0.25/0.55).
        let expected = (0.10 / 0.65) * (0.10 / 0.20) * (0.25 / 0.55)
        #expect(abs(analysis.mapsim(from: 0, to: 2) - expected) < 1e-12)
        #expect(abs(analysis.mapsimDistance(from: 0, to: 2) - (-log2(expected))) < 1e-12)
    }

    @Test func mapsimThroughHierarchy() {
        let analysis = PartitionAnalysis(threeLevelPartition())
        // Sibling submodules under [1]: exit [1,1] → enter [1,2] within [1]'s
        // codebook → visit 2.
        let sibling = (0.05 / 0.40) * (0.07 / 0.23) * (0.15 / 0.23)
        #expect(abs(analysis.mapsim(from: 0, to: 2) - sibling) < 1e-12)
        // Full ascent and descent: exit [1,1], exit [1], enter [2] at root,
        // visit 3.
        let across = (0.05 / 0.40) * (0.10 / 0.23) * (0.10 / 0.22) * (0.30 / 0.62)
        #expect(abs(analysis.mapsim(from: 0, to: 3) - across) < 1e-12)
        // Asymmetric by construction.
        let reverse = (0.12 / 0.62) * (0.12 / 0.22) * (0.06 / 0.23) * (0.20 / 0.40)
        #expect(abs(analysis.mapsim(from: 3, to: 0) - reverse) < 1e-12)
        #expect(analysis.mapsim(from: 0, to: 3) != analysis.mapsim(from: 3, to: 0))
    }

    @Test func mapsimUnknownNodeIsUnreachable() {
        let analysis = PartitionAnalysis(twoLevelPartition())
        #expect(analysis.mapsim(from: 0, to: 99) == 0)
        #expect(analysis.mapsimDistance(from: 0, to: 99) == .infinity)
    }

    @Test func centralityMatchesEquation50() {
        let analysis = PartitionAnalysis(twoLevelPartition())
        // λ = −(r − p_u)·log₂((r − p_u)/r) with r = 0.65 for module [1].
        let rest = 0.65 - 0.30
        #expect(abs(analysis.centrality(of: 0) - (-rest * log2(rest / 0.65))) < 1e-12)
        #expect(analysis.centrality(of: 99) == 0)
    }

    @Test func nmiIdenticalPartitionsIsOne() {
        let partition = threeLevelPartition()
        #expect(abs(PartitionAnalysis.nmi(partition, partition) - 1.0) < 1e-12)
        #expect(abs(PartitionAnalysis.nmi(partition, partition, at: .top) - 1.0) < 1e-12)
    }

    @Test func nmiHandComputedValue() {
        // a: {0,1} vs {2,3}; b: {0,1,2} vs {3} — NMI (natural log, arithmetic
        // mean normalization) = 0.21576155433483564 / 0.6277411625893767
        // ≈ 0.343711 (hand-computed).
        let a: [Int: AnyHashable] = [0: "x", 1: "x", 2: "y", 3: "y"]
        let b: [Int: AnyHashable] = [0: "p", 1: "p", 2: "p", 3: "q"]
        #expect(abs(PartitionAnalysis.nmi(a, b) - 0.34371102) < 1e-6)
        // Symmetric.
        #expect(abs(PartitionAnalysis.nmi(a, b) - PartitionAnalysis.nmi(b, a)) < 1e-12)
    }

    @Test func nmiComparesSharedNodesOnly() {
        // Disjoint node sets → 0; the two-level partition against its own
        // top-level labels → 1 (labels coincide at both depths here).
        let partition = twoLevelPartition()
        let disjoint: [Int: AnyHashable] = [10: "x", 11: "y"]
        #expect(PartitionAnalysis.nmi(PartitionAnalysis.labels(of: partition, at: .leaf), disjoint) == 0)
    }

    @Test func coverAgreementIsDeterministicAndCentered() {
        let partition = threeLevelPartition()
        // Cover aligned with top modules.
        let cover = [0: 1, 1: 1, 2: 1, 3: 2, 4: 2]
        let first = PartitionAnalysis.coverAgreement(partition, cover: cover, at: .top, permutations: 200, seed: 7)
        let second = PartitionAnalysis.coverAgreement(partition, cover: cover, at: .top, permutations: 200, seed: 7)
        #expect(first == second)
        #expect(abs(first.nmi - 1.0) < 1e-12)
        #expect(first.comparedNodes == 5)
        // A perfectly aligned cover must sit above its permutation null.
        #expect(first.nmi > first.nullMean)
        let differentSeed = PartitionAnalysis.coverAgreement(partition, cover: cover, at: .top, permutations: 200, seed: 8)
        #expect(differentSeed.nullMean != first.nullMean || differentSeed.nullStd != first.nullStd)
    }

    @Test func membershipDiffEmptyOnIdenticalPartitions() {
        let partition = threeLevelPartition()
        let diff = PartitionAnalysis.membershipDiff(partition, partition)
        #expect(diff.isEmpty)
        #expect(diff.stableCount == 5)
    }

    @Test func membershipDiffTracksMovesAndPresence() {
        let old = threeLevelPartition()
        var newPaths = old.nodePaths
        newPaths[2] = Partition.ModulePath([2])   // node 2 moves
        newPaths[4] = nil                          // node 4 disappears
        newPaths[9] = Partition.ModulePath([1, 1]) // node 9 appears
        let new = Partition(
            codelength: old.codelength, oneLevelCodelength: old.oneLevelCodelength,
            relativeCodelengthSavings: old.relativeCodelengthSavings,
            numLevels: old.numLevels, numTopModules: old.numTopModules,
            numLeafModules: old.numLeafModules, modules: old.modules,
            nodePaths: newPaths, nodeFlow: old.nodeFlow
        )
        let diff = PartitionAnalysis.membershipDiff(old, new)
        #expect(diff.moved == [2: .init(from: Partition.ModulePath([1, 2]), to: Partition.ModulePath([2]))])
        #expect(diff.onlyInOld == [4])
        #expect(diff.onlyInNew == [9])
        #expect(diff.stableCount == 3)
        #expect(!diff.isEmpty)
    }

    /// Fixture engine: canned partitions per regularization strength, so the
    /// sweep's plateau/collapse extraction is testable without the core.
    struct SweepFixtureEngine: InfomapRunning {
        /// strength → (topModules, leafModules, savings)
        let table: [Double: (Int, Int, Double)]

        func run(_ network: FlowNetwork, options: InfomapOptions) async throws -> Partition {
            guard network.bipartiteStartID == nil else {
                throw InfomapError.unsupportedConfiguration(reason: "sweep must strip bipartite")
            }
            guard case .bayesian(let strength) = options.regularization,
                  let (top, leaf, savings) = table[strength]
            else { throw InfomapError.invalidNetwork(reason: "unexpected sweep options") }
            let leafPath = Partition.ModulePath([1])
            return Partition(
                codelength: 1, oneLevelCodelength: 1.0 / (1.0 - savings),
                relativeCodelengthSavings: savings,
                numLevels: 2, numTopModules: top, numLeafModules: leaf,
                modules: [leafPath: .init(path: leafPath, flow: 1, enterFlow: 0, exitFlow: 0, childCount: 0, nodes: [0])],
                nodePaths: [0: leafPath], nodeFlow: [0: 1]
            )
        }
    }

    @Test func strengthSweepFindsPlateauAndCollapse() async throws {
        var network = FlowNetwork(bipartiteStartID: 4)
        network.addLink(from: 0, to: 4)
        let engine = SweepFixtureEngine(table: [
            0.1: (9, 20, 0.40),
            0.2: (8, 16, 0.35),
            0.3: (8, 15, 0.33),
            0.4: (8, 15, 0.32),
            0.5: (1, 1, 0.0),
            0.8: (1, 1, 0.0),
        ])
        let result = try await StrengthSweep.run(
            network: network, options: InfomapOptions(),
            strengths: [0.8, 0.1, 0.2, 0.3, 0.4, 0.5],  // unsorted on purpose
            engine: engine
        )
        #expect(result.points.map(\.strength) == [0.1, 0.2, 0.3, 0.4, 0.5, 0.8])
        #expect(result.plateauModuleCount == 8)
        #expect(result.collapseStrength == 0.5)
        #expect(result.strippedBipartiteDeclaration)
    }

    @Test func mapsimDisconnectedComponentsIsZeroNotNaN() {
        // Two disconnected components: zero enter/exit flow between the top
        // modules, so the cross-component walk has a zero-rate step. The
        // contract is 0 (distance +∞) — never NaN from 0/0.
        let m1 = Partition.ModulePath([1])
        let m2 = Partition.ModulePath([2])
        let partition = Partition(
            codelength: 2, oneLevelCodelength: 2, relativeCodelengthSavings: 0,
            numLevels: 2, numTopModules: 2, numLeafModules: 2,
            modules: [
                m1: .init(path: m1, flow: 0.5, enterFlow: 0, exitFlow: 0, childCount: 0, nodes: [0, 1]),
                m2: .init(path: m2, flow: 0.5, enterFlow: 0, exitFlow: 0, childCount: 0, nodes: [2, 3]),
            ],
            nodePaths: [0: m1, 1: m1, 2: m2, 3: m2],
            nodeFlow: [0: 0.25, 1: 0.25, 2: 0.3, 3: 0.2]
        )
        let analysis = PartitionAnalysis(partition)
        #expect(analysis.mapsim(from: 0, to: 2) == 0)
        #expect(analysis.mapsimDistance(from: 0, to: 2) == .infinity)
        // Within a component the rates are fine: p_v / r_m with r = 0 + 0.5.
        #expect(abs(analysis.mapsim(from: 0, to: 1) - 0.25 / 0.5) < 1e-12)
    }

    @Test func strengthSweepIgnoresTransientCollapse() async throws {
        // A one-module point mid-sweep (near-tie search noise) must not be
        // reported as the density margin, nor truncate the plateau.
        var network = FlowNetwork()
        network.addLink(from: 0, to: 1)
        let engine = SweepFixtureEngine(table: [
            0.1: (2, 4, 0.30),
            0.2: (1, 1, 0.0),   // transient
            0.3: (8, 16, 0.35),
            0.4: (8, 15, 0.34),
            0.5: (1, 1, 0.0),   // real collapse: stays collapsed to the end
        ])
        let result = try await StrengthSweep.run(
            network: network, options: InfomapOptions(),
            strengths: [0.1, 0.2, 0.3, 0.4, 0.5], engine: engine
        )
        #expect(result.collapseStrength == 0.5)
        #expect(result.plateauModuleCount == 8)
    }

    @Test func strengthSweepCollapsedThroughout() async throws {
        var network = FlowNetwork()
        network.addLink(from: 0, to: 1)
        let engine = SweepFixtureEngine(table: [0.1: (1, 1, 0.0), 0.2: (1, 1, 0.0)])
        let result = try await StrengthSweep.run(
            network: network, options: InfomapOptions(),
            strengths: [0.1, 0.2], engine: engine
        )
        #expect(result.collapseStrength == 0.1)
        #expect(result.plateauModuleCount == nil)
    }

    @Test func strengthSweepStopsWhenCancelled() async throws {
        var network = FlowNetwork()
        network.addLink(from: 0, to: 1)
        let engine = SweepFixtureEngine(table: [0.1: (5, 9, 0.2)])
        let task = Task<StrengthSweep.Result, any Error> {
            // Deterministic: enter the sweep only once cancellation is set.
            while !Task.isCancelled { await Task.yield() }
            return try await StrengthSweep.run(
                network: network, options: InfomapOptions(),
                strengths: [0.1], engine: engine
            )
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func strengthSweepWithoutCollapse() async throws {
        var network = FlowNetwork()
        network.addLink(from: 0, to: 1)
        let engine = SweepFixtureEngine(table: [0.1: (5, 9, 0.2), 0.2: (5, 8, 0.18)])
        let result = try await StrengthSweep.run(
            network: network, options: InfomapOptions(),
            strengths: [0.1, 0.2], engine: engine
        )
        #expect(result.collapseStrength == nil)
        #expect(result.plateauModuleCount == 5)
        #expect(!result.strippedBipartiteDeclaration)
    }
}
