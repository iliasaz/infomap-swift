// The minimal engine surface InfomapKit drives via Swift/C++ interop.
//
// This header is deliberately self-contained (standard library only): it is
// the module's public face, so it must not drag the vendored Infomap headers
// into every Swift compilation. Columnar std::vector fields keep the imported
// API to types the CxxStdlib overlay handles on both libc++ and libstdc++.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace cinfomap {

using UInt8Vector = std::vector<std::uint8_t>;
using UInt32Vector = std::vector<std::uint32_t>;
using Int32Vector = std::vector<std::int32_t>;
using DoubleVector = std::vector<double>;

/// Everything InfomapKit needs from one detection run. `rows` are every tree
/// position below the root in depth-first pre-order — modules and leaf nodes
/// interleaved, paths CSR-encoded with 1-based components (tree-file
/// convention; a leaf's last component is its position within its leaf
/// module). enter/exit flow is meaningful for module rows only.
struct RunResult {
  bool ok = false;
  /// Verbatim core error when !ok (the C++ exception never crosses to Swift).
  std::string errorMessage;

  double codelength = 0;
  double oneLevelCodelength = 0;
  double relativeCodelengthSavings = 0;
  std::uint32_t numLevels = 0;
  std::uint32_t numTopModules = 0;

  UInt8Vector rowIsLeaf;
  UInt32Vector rowPathLength;
  UInt32Vector rowPathFlat;
  DoubleVector rowFlow;
  DoubleVector rowEnterFlow;
  DoubleVector rowExitFlow;
  /// Physical node id for leaf rows; 0 for module rows.
  UInt32Vector rowNodeId;
};

/// Builds the network (links columns + optional bipartite start id + optional
/// per-node categorical metadata), runs map-equation minimization with the
/// given Infomap flags string, and extracts the full tree.
///
/// Never throws: every C++ exception — including the core's non-std
/// CleanExit — is caught and reported through `errorMessage`. Not
/// concurrency-safe across calls (the core's logging statics); callers
/// serialize (InfomapKit holds a process-wide gate).
RunResult run(const std::string& flags,
              const UInt32Vector& sources,
              const UInt32Vector& targets,
              const DoubleVector& weights,
              std::int64_t bipartiteStartId,
              const UInt32Vector& metaNodes,
              const Int32Vector& metaCategories);

} // namespace cinfomap
