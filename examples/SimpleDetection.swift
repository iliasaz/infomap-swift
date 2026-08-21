// The "two triangles" classic (upstream examples/python/simple.py): the
// smallest network with obvious community structure — two triangles joined
// by a single bridge link.

import Foundation
import InfomapKit

func simpleDetection() async throws {
    section("Simple detection: two triangles")

    var network = FlowNetwork()
    for (a, b) in [(0, 1), (0, 2), (1, 2)] { network.addLink(from: a, to: b) }
    for (a, b) in [(3, 4), (3, 5), (4, 5)] { network.addLink(from: a, to: b) }
    network.addLink(from: 2, to: 3)  // the bridge

    // Defaults: multilevel, undirected flow, 50 trials, seed 42. Equal
    // (network, options) reproduces the identical partition on a platform.
    let partition = try await InfomapEngine.shared.run(network, options: InfomapOptions())

    print("codelength: \(String(format: "%.4f", partition.codelength)) bits",
          "(one-level \(String(format: "%.4f", partition.oneLevelCodelength)),",
          "savings \(String(format: "%.1f", partition.relativeCodelengthSavings * 100))%)")
    print("top modules: \(partition.numTopModules), levels: \(partition.numLevels)")

    for node in 0...5 {
        let path = partition.path(of: node)!
        print("node \(node) -> module \(path.components.map(String.init).joined(separator: ":"))",
              "flow \(String(format: "%.4f", partition.nodeFlow[node] ?? 0))")
    }

    // Per-module flow rates (the map equation's raw material): module flow,
    // enter rate q_m↷, exit rate q_m↶.
    for (path, module) in partition.modules.sorted(by: { $0.key.components.lexicographicallyPrecedes($1.key.components) }) {
        print("module \(path.components)",
              "flow \(String(format: "%.4f", module.flow))",
              "enter \(String(format: "%.4f", module.enterFlow))",
              "exit \(String(format: "%.4f", module.exitFlow))")
    }
}
