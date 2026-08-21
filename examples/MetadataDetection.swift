// The content map equation (paper §6.1): per-node categorical metadata
// steers the partition toward category-coherent modules at a chosen
// encoding rate. Upstream analog: examples/python/metadata.py.

import Foundation
import InfomapKit

func metadataDetection() async throws {
    section("Metadata: the content map equation")

    // Two 4-cliques with a bridge...
    var network = FlowNetwork()
    for group in 0...1 {
        let base = group * 4
        for a in base..<(base + 4) {
            for b in (a + 1)..<(base + 4) {
                network.addLink(from: a, to: b)
            }
        }
    }
    network.addLink(from: 3, to: 4)

    // ...and a category per node. Labels must reference linked nodes and be
    // non-negative (-1 is the core's internal "unlabeled" sentinel).
    var options = InfomapOptions(seed: 42, trials: 20)
    options.metadata = .init(
        labels: Dictionary(uniqueKeysWithValues: (0...7).map { ($0, $0 < 4 ? 0 : 1) }),
        rate: 1.0
    )

    let partition = try await InfomapEngine.shared.run(network, options: options)
    print("top modules: \(partition.numTopModules)")
    for node in 0...7 {
        print("node \(node) (category \(node < 4 ? 0 : 1)) -> module \(partition.topModule(of: node)!)")
    }
    // Note: `codelength` excludes the metadata codebook's contribution while
    // `oneLevelCodelength` includes the one-level metadata entropy, so
    // relative savings from a metadata run are not comparable to a plain run.
    print("codelength \(String(format: "%.4f", partition.codelength)) bits",
          "(module-label entropy is the Gate-G5 secondary metric)")
}
