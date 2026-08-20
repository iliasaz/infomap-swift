import Foundation
import Testing
@testable import InfomapKit

/// Spec-stage tests: exercise the parts of the contract that are already
/// executable — the data model and the engine's pre-flight guard. Engine and
/// analysis behavior get golden-partition tests in roadmap steps 3–4.
@Suite struct SpecStageTests {
    func toyNetwork(bipartite: Bool = true) -> FlowNetwork {
        var network = FlowNetwork(bipartiteStartID: bipartite ? 8 : nil)
        for episode in 0..<4 {
            for entity in 8..<12 { network.addIncidence(hyperedge: episode, vertex: entity) }
        }
        for episode in 4..<8 {
            for entity in 12..<16 { network.addIncidence(hyperedge: episode, vertex: entity) }
        }
        network.addLink(from: 0, to: 13, weight: 0.3)
        return network
    }

    @Test func networkAccumulatesLinksAndNodes() {
        let network = toyNetwork()
        #expect(network.links.count == 33)
        #expect(network.nodeIDs.count == 16)
        #expect(network.bipartiteStartID == 8)
    }

    @Test func optionsDefaultsMatchValidatedConfiguration() {
        let options = InfomapOptions()
        #expect(options.hierarchy == .multilevel)
        #expect(options.flow == .undirected)
        #expect(options.regularization == .off)
        #expect(options.trials == 50)
        #expect(options.markovTime == 1.0)
    }

    @Test func regularizedBipartiteIsRefused() async {
        // The iliasaz/infomap#1 guard is part of the contract from day one.
        var options = InfomapOptions()
        options.regularization = .bayesianDefault
        await #expect(throws: InfomapError.self) {
            try await InfomapEngine.shared.run(toyNetwork(), options: options)
        }
        #expect(throws: InfomapError.self) {
            try InfomapEngine.validate(network: toyNetwork(), options: options)
        }
        // The same options without the bipartite declaration pass validation.
        #expect(throws: Never.self) {
            try InfomapEngine.validate(network: toyNetwork(bipartite: false), options: options)
        }
    }

    @Test func invalidWeightsAreRefused() {
        var network = FlowNetwork()
        network.addLink(from: 0, to: 1, weight: -1.0)
        #expect(throws: InfomapError.self) {
            try InfomapEngine.validate(network: network, options: InfomapOptions())
        }
        #expect(throws: InfomapError.self) {
            try InfomapEngine.validate(network: FlowNetwork(), options: InfomapOptions())
        }
    }

    @Test func modulePathHierarchyAccessors() {
        let path = Partition.ModulePath([2, 1, 3])
        #expect(path.depth == 3)
        #expect(path.parent == Partition.ModulePath([2, 1]))
        #expect(path.prefix(depth: 1) == Partition.ModulePath([2]))
        #expect(Partition.ModulePath([2]).parent == nil)
    }

    @Test func partitionAssignmentAccessors() throws {
        let leafA = Partition.ModulePath([1, 1])
        let leafB = Partition.ModulePath([2, 1])
        let partition = Partition(
            codelength: 1.9, oneLevelCodelength: 2.4, relativeCodelengthSavings: 0.2083,
            numLevels: 3, numTopModules: 2, numLeafModules: 2,
            modules: [
                Partition.ModulePath([1]): .init(
                    path: .init([1]), flow: 0.6, enterFlow: 0.05, exitFlow: 0.05,
                    childCount: 1, nodes: []
                ),
                leafA: .init(
                    path: leafA, flow: 0.55, enterFlow: 0.04, exitFlow: 0.04,
                    childCount: 0, nodes: [0, 1]
                ),
                Partition.ModulePath([2]): .init(
                    path: .init([2]), flow: 0.4, enterFlow: 0.05, exitFlow: 0.05,
                    childCount: 1, nodes: []
                ),
                leafB: .init(
                    path: leafB, flow: 0.36, enterFlow: 0.03, exitFlow: 0.03,
                    childCount: 0, nodes: [2]
                ),
            ],
            nodePaths: [0: leafA, 1: leafA, 2: leafB],
            nodeFlow: [0: 0.3, 1: 0.25, 2: 0.36]
        )
        #expect(partition.topModule(of: 2) == 2)
        #expect(partition.leafModule(of: 0) == leafA)
        #expect(partition.module(of: 1, atDepth: 1) == Partition.ModulePath([1]))
        #expect(partition.module(of: 1, atDepth: 9) == leafA)
        #expect(partition.module(at: leafB)?.isLeaf == true)
        #expect(partition.module(at: Partition.ModulePath([1]))?.isLeaf == false)
        #expect(partition.path(of: 99) == nil)

        // Partition round-trips through Codable (substrate-state persistence).
        let data = try JSONEncoder().encode(partition)
        let decoded = try JSONDecoder().decode(Partition.self, from: data)
        #expect(decoded == partition)
    }
}
