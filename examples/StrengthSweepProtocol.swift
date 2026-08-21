// The sparse-graph honesty protocol (map-equation-basins experiment §5.4):
// never gate on default-strength regularized savings — sweep the Bayesian
// regularization strength and report the plateau and the collapse point
// (the corpus's density margin).

import Foundation
import InfomapKit

func strengthSweepProtocol() async throws {
    section("Strength sweep: the sparse-graph honesty protocol")

    // A sparse two-community graph — exactly the regime where the Dirichlet
    // prior may honestly answer "no structure".
    var network = FlowNetwork()
    for (a, b) in [(0, 1), (1, 2), (2, 0), (2, 3)] { network.addLink(from: a, to: b) }
    for (a, b) in [(3, 4), (4, 5), (5, 3)] { network.addLink(from: a, to: b) }

    // The sweep strips any bipartite declaration itself (iliasaz/infomap#1)
    // and records that it did.
    let result = try await StrengthSweep.run(
        network: network,
        options: InfomapOptions(seed: 42, trials: 20),
        engine: InfomapEngine.shared
    )

    print("strength  top-modules  savings")
    for point in result.points {
        print(String(format: "%7.2f  %11d  %6.1f%%",
                     point.strength, point.topModules, point.relativeSavings * 100))
    }
    if let plateau = result.plateauModuleCount {
        print("plateau: \(plateau) top modules")
    } else {
        print("plateau: none — no structured regime in the swept range")
    }
    if let collapse = result.collapseStrength {
        print("collapse point: strength \(collapse) (density margin of this corpus)")
    } else {
        print("collapse point: none within the swept range")
    }
}
