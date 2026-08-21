// Comparing partitions and covers: multi-seed agreement (NMI), rebuild
// regression (membership diff), and cover agreement against a permutation
// null — the Gate-G5 statistic. Upstream analog:
// examples/python/evaluate-partition.py.

import Foundation
import InfomapKit

func evaluateAndCompare() async throws {
    section("Evaluate & compare: NMI, membership diff, cover agreement")

    // Three 3-cliques in a ring.
    var network = FlowNetwork()
    for clique in 0...2 {
        let base = clique * 3
        for a in base..<(base + 3) {
            for b in (a + 1)..<(base + 3) {
                network.addLink(from: a, to: b)
            }
        }
    }
    for (a, b) in [(2, 3), (5, 6), (8, 0)] { network.addLink(from: a, to: b) }

    // Solution-landscape check: do independent seeds agree?
    let seedA = try await InfomapEngine.shared.run(network, options: InfomapOptions(seed: 42, trials: 20))
    let seedB = try await InfomapEngine.shared.run(network, options: InfomapOptions(seed: 7, trials: 20))
    print("NMI(seed 42, seed 7) at leaf level:",
          String(format: "%.4f", PartitionAnalysis.nmi(seedA, seedB)))

    // Rebuild regression: an unchanged corpus must produce an empty diff.
    let rebuilt = try await InfomapEngine.shared.run(network, options: InfomapOptions(seed: 42, trials: 20))
    let diff = PartitionAnalysis.membershipDiff(seedA, rebuilt)
    print("rebuild diff empty: \(diff.isEmpty) (stable nodes: \(diff.stableCount))")

    // Cover agreement vs an external labeling, with an empirical null from
    // seeded permutations — report the z-score, not raw NMI: fine partitions
    // inflate chance agreement.
    let cover = Dictionary(uniqueKeysWithValues: (0...8).map { ($0, $0 / 3) })
    let agreement = PartitionAnalysis.coverAgreement(
        seedA, cover: cover, at: .top, permutations: 500, seed: 42
    )
    print("cover NMI \(String(format: "%.3f", agreement.nmi)),",
          "null \(String(format: "%.3f", agreement.nullMean)) ± \(String(format: "%.3f", agreement.nullStd)),",
          "z = \(String(format: "%.1f", agreement.z))")
}
