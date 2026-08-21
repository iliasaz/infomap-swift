#include "CInfomapBridge.h"

#include "Infomap.h"

namespace cinfomap {

RunResult run(const std::string& flags,
              const UInt32Vector& sources,
              const UInt32Vector& targets,
              const DoubleVector& weights,
              std::int64_t bipartiteStartId,
              const UInt32Vector& metaNodes,
              const Int32Vector& metaCategories)
{
  RunResult result;
  try {
    infomap::InfomapWrapper engine(flags);

    for (std::size_t i = 0; i < sources.size(); ++i) {
      engine.addLink(sources[i], targets[i], weights[i]);
    }
    if (bipartiteStartId >= 0) {
      engine.setBipartiteStartId(static_cast<unsigned int>(bipartiteStartId));
    }
    for (std::size_t i = 0; i < metaNodes.size(); ++i) {
      // Programmatic metadata engages MetaMapEquation automatically once
      // numMetaDataColumns is non-zero; no activation flag exists.
      engine.network().addMetaData(metaNodes[i], metaCategories[i]);
    }

    engine.run();

    result.codelength = engine.codelength();
    result.oneLevelCodelength = engine.getOneLevelCodelength();
    result.relativeCodelengthSavings = engine.getRelativeCodelengthSavings();
    result.numLevels = engine.maxTreeDepth();
    result.numTopModules = engine.numTopModules();

    for (auto it = engine.iterTree(); !it.isEnd(); ++it) {
      if (it.depth() == 0) continue; // root carries no path
      auto& node = *it;
      const auto& path = it.path();
      result.rowIsLeaf.push_back(node.isLeaf() ? 1 : 0);
      result.rowPathLength.push_back(static_cast<std::uint32_t>(path.size()));
      result.rowPathFlat.insert(result.rowPathFlat.end(), path.begin(), path.end());
      result.rowFlow.push_back(node.data.flow);
      result.rowEnterFlow.push_back(node.data.enterFlow);
      result.rowExitFlow.push_back(node.data.exitFlow);
      result.rowNodeId.push_back(node.isLeaf() ? node.physicalId : 0);
    }

    result.ok = true;
  } catch (const std::exception& e) {
    result.errorMessage = e.what();
  } catch (...) {
    // Includes the core's CleanExit (not derived from std::exception),
    // reachable only via help/version flags InfomapKit never forwards.
    result.errorMessage = "Infomap core failed with a non-standard exception";
  }
  return result;
}

} // namespace cinfomap
