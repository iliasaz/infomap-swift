import Foundation
import Testing
@testable import InfomapKit

/// Regression coverage for the iliasaz/infomap#1 fix (vendored pin
/// `0853262c`, fix/regularized-bipartite-negative-enter-flow): Bayesian
/// regularization combined with a bipartite declaration used to abort with
/// "negative enter flow" on small/uneven networks and silently return a
/// degenerate over-fragmented partition on larger ones. The pip reference
/// implementation (2.15.1) still carries the bug, so these are property
/// regressions against the failure modes — not golden-parity tests.
@Suite struct RegularizedBipartiteTests {
    static func flowsAreSane(_ partition: Partition) {
        for (path, module) in partition.modules {
            #expect(module.enterFlow >= 0 && module.enterFlow.isFinite, "module \(path.components) enterFlow \(module.enterFlow)")
            #expect(module.exitFlow >= 0 && module.exitFlow.isFinite, "module \(path.components) exitFlow \(module.exitFlow)")
            #expect(module.flow >= 0 && module.flow.isFinite, "module \(path.components) flow \(module.flow)")
        }
        for (node, flow) in partition.nodeFlow {
            #expect(flow >= 0 && flow.isFinite, "node \(node) flow \(flow)")
        }
    }

    @Test func toyRegularizedBipartiteRuns() async throws {
        // The abort-class repro size: small, uneven bipartite network.
        // Observed with the fix (macOS + Linux): 2 top modules at both
        // strengths, savings decreasing toward the null as the prior
        // strengthens (0.166 at 0.3, 0.030 at 1.0).
        let fixture = try GoldenPartitionTests.loadFixture("toy-multilevel")
        let network = GoldenPartitionTests.network(from: fixture)
        var savings: [Double] = []
        for strength in [0.3, 1.0] {
            var options = InfomapOptions(seed: 42, trials: 10)
            options.regularization = .bayesian(strength: strength)
            let partition = try await InfomapEngine.shared.run(network, options: options)
            Self.flowsAreSane(partition)
            #expect(partition.numTopModules == 2, "strength \(strength)")
            savings.append(partition.relativeCodelengthSavings)
        }
        // The Dirichlet prior pulls toward the one-module null monotonically.
        #expect(savings[0] > savings[1])
        #expect(savings[1] > 0)
    }

    @Test func planted8RegularizedBipartiteIsNotDegenerate() async throws {
        // The silent-degeneracy repro class: the larger planted network WITH
        // its bipartite declaration, regularized.
        let fixture = try GoldenPartitionTests.loadFixture("planted8-multilevel")
        let network = GoldenPartitionTests.network(from: fixture)
        var options = InfomapOptions(seed: 42, trials: 10)
        options.regularization = .bayesian(strength: 0.3)
        let partition = try await InfomapEngine.shared.run(network, options: options)
        Self.flowsAreSane(partition)

        // The bug's degenerate mode over-fragmented far beyond the planted
        // scale (8 groups / 16 sub-communities in 192 nodes). Observed with
        // the fix: 10 top modules, savings 0.163, NMI(top) 0.96 vs the
        // unregularized partition — bounds below leave head-room for
        // cross-platform near-tie variation, not for degeneracy.
        #expect((2...20).contains(partition.numTopModules))
        #expect(partition.relativeCodelengthSavings > 0.05)

        let plain = try await InfomapEngine.shared.run(
            network, options: InfomapOptions(seed: 42, trials: 10)
        )
        #expect(PartitionAnalysis.nmi(partition, plain, at: .top) > 0.7)

        // Determinism holds for the new code path too.
        let again = try await InfomapEngine().run(network, options: options)
        #expect(partition == again)
    }

    @Test func sweepRunsBipartiteNetworksAsGiven() async throws {
        // The sweep no longer strips the bipartite declaration — possible
        // now that the pin carries the fix. End-to-end through the real
        // engine on the bipartite toy: structure survives both strengths
        // (observed: 2 top modules at 0.3 and 1.0 on macOS and Linux).
        let fixture = try GoldenPartitionTests.loadFixture("toy-multilevel")
        let network = GoldenPartitionTests.network(from: fixture)
        let result = try await StrengthSweep.run(
            network: network,
            options: InfomapOptions(seed: 42, trials: 10),
            strengths: [0.3, 1.0],
            engine: InfomapEngine.shared
        )
        #expect(result.points.map(\.topModules) == [2, 2])
        #expect(result.plateauModuleCount == 2)
        #expect(result.collapseStrength == nil)
    }
}
