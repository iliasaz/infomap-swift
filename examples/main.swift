// Runnable InfomapKit examples: `swift run infomap-example`.
//
// Each file in this directory is one self-contained example, in the spirit
// of the upstream repo's examples/python/{simple,bipartite,metadata,
// evaluate-partition}.py. Read them in this order — each builds on ideas
// from the previous one.

import Foundation

func section(_ title: String) {
    print("\n=== \(title) ===")
}

do {
    try await simpleDetection()
    try await hypergraphBasins()
    try await metadataDetection()
    try await evaluateAndCompare()
    try await strengthSweepProtocol()
} catch {
    print("example failed: \(error)")
    exit(1)
}
