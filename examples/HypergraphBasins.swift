// Bipartite hyperedge-incidence detection — the primary use case:
// hyperedges (episodes) as primary nodes,
// entities as feature nodes, hub-penalized incidence weights, then
// partition-analysis on the result (mapsim tunneling costs, centrality).
// Upstream analog: examples/python/bipartite.py.

import Foundation
import InfomapKit

func hypergraphBasins() async throws {
    section("Hypergraph basins: bipartite incidence + analysis")

    // Episodes 0...5, entities 100... (bipartiteStartID = 100 must itself be
    // a linked feature node). Two clusters; episode 2 bridges them.
    let incidences: [(episode: Int, entity: Int)] = [
        (0, 100), (0, 101), (0, 102),
        (1, 100), (1, 101),
        (2, 101), (2, 102), (2, 103),  // the bridge episode
        (3, 103), (3, 104), (3, 105),
        (4, 103), (4, 104),
        (5, 104), (5, 105),
    ]

    // The hub penalty γ_e(v) = 1 / log2(1 + deg(entity)) — high-degree
    // entities carry less specificity per incidence (paper Eqs. 29–30).
    var degree: [Int: Int] = [:]
    for i in incidences { degree[i.entity, default: 0] += 1 }

    var network = FlowNetwork(bipartiteStartID: 100)
    for i in incidences {
        let weight = 1.0 / log2(1.0 + Double(degree[i.entity]!))
        network.addIncidence(hyperedge: i.episode, vertex: i.entity, weight: weight)
    }

    let partition = try await InfomapEngine.shared.run(
        network, options: InfomapOptions(seed: 42, trials: 20)
    )
    print("top modules: \(partition.numTopModules), savings",
          String(format: "%.1f%%", partition.relativeCodelengthSavings * 100))
    for episode in 0...5 {
        print("episode \(episode) -> basin \(partition.topModule(of: episode)!)")
    }

    // Everything below is a pure function of the partition — no second
    // engine call.
    let analysis = PartitionAnalysis(partition)

    // mapsim distance = the tunneling cost in bits: defined even for pairs
    // with no observed link, asymmetric, and higher across basins than
    // within them.
    let within = analysis.mapsimDistance(from: 0, to: 1)
    let across = analysis.mapsimDistance(from: 0, to: 5)
    print("tunneling cost 0->1 (same basin):  \(String(format: "%.2f", within)) bits")
    print("tunneling cost 0->5 (cross basin): \(String(format: "%.2f", across)) bits")

    // Map-equation centrality distinguishes bridges from hubs.
    for episode in [0, 2] {
        print("centrality(episode \(episode)) =",
              String(format: "%.4f", analysis.centrality(of: episode)))
    }
}
