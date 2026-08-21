#!/usr/bin/env python3
"""Golden-partition fixture generator for infomap-swift.

Runs the reference Python implementation (pip package ``infomap`` 2.15.1) on
small deterministic synthetic networks and records both the exact input
network and the full partition output, so the Swift/C++ binding can be
verified against the reference rather than against itself.

Usage (from the repo root)::

    python3 scripts/generate_golden_fixtures.py

Writes one JSON file per fixture into ``Tests/InfomapKitTests/Fixtures/``.
Running twice produces byte-identical output (seeded ``random.Random``,
``--seed 42`` engine runs, insertion-ordered dicts, ``repr``-precision
floats via the ``json`` module).

Networks
--------
* **toy** — the 16-node bipartite toy from ``SpecStageTests.toyNetwork()``:
  episodes 0..3 x entities 8..11, episodes 4..7 x entities 12..15 (weight 1),
  plus one cross link 0->13 (weight 0.3); ``bipartiteStartId`` 8.
* **planted8** — a planted-partition hyperedge-incidence network in the style
  of ``noema/experiments/map-equation-basins`` §3 (that experiment used real
  corpora; no synthetic generator existed there, so this one is designed to
  its method section): bipartite episodes x entities, 8 planted groups, each
  group split into 2 planted sub-communities (so multilevel recovery is a
  genuine 3-level hierarchy: 8 top modules x 2 submodules), a within-group
  glue incidence per sub-community and a ring of 8 cross-group bridge
  incidences for connectivity, link weight = the experiment's hub penalty
  ``1/log2(1 + deg(entity))`` with ``deg`` computed deterministically over
  the finished incidence list. Membership sampling uses seeded stdlib
  ``random.Random(42)`` — no numpy.
* **directed** — 3 directed 10-node rings (i -> i+1 weight 1.0, chord
  i -> i+2 weight 0.5 for intra-ring mixing) bridged by 6 weak cross links
  (weight 0.25) into one strongly connected 30-node graph. Fully
  deterministic, no RNG.

Fixture schema
--------------
::

    { "name": ..., "flags": "<exact flags string passed to Infomap(...)>",
      "notes": "<path/flow conventions>",
      "network": { "bipartiteStartId": int|null, "links": [[s, t, w], ...],
                   "meta": {"<nodeId>": int, ...}|null },
      "expected": {
        "codelength": float, "oneLevelCodelength": float,
        "relativeCodelengthSavings": float, "numLevels": int,
        "numTopModules": int, "numLeafModules": int,
        "nodes":   [{"id": int, "path": [int, ...], "flow": float}, ...],
        "modules": [{"path": [int, ...], "flow": float, "enterFlow": float,
                     "exitFlow": float, "childCount": int}, ...] } }

Python property map (what each JSON key was read from, infomap 2.15.1):

* ``expected.codelength``                = ``im.codelength``
* ``expected.oneLevelCodelength``        = ``im.one_level_codelength``
* ``expected.relativeCodelengthSavings`` = ``im.relative_codelength_savings``
  (equals ``1 - codelength/oneLevelCodelength``)
* ``expected.numLevels``       = ``im.num_levels`` (counts module levels below
  the root INCLUDING the leaf-node level; a flat two-level partition is 2)
* ``expected.numTopModules``   = ``im.num_top_modules``
* ``expected.numLeafModules``  = ``im.num_leaf_modules``
* per tree node, iterating ``im.tree`` (depth-first from the root; recorded
  in traversal order):
  - ``path``      = ``node.path`` — tuple of 1-based child indices. For a
    LEAF node the LAST component is the leaf's position among its leaf
    module's children, i.e. the leaf-module path is ``path[:-1]``.
  - ``flow``      = ``node.data.flow``
  - ``enterFlow`` = ``node.data.enter_flow`` (modules only; on leaves the
    engine stores unrelated values in these slots)
  - ``exitFlow``  = ``node.data.exit_flow`` (modules only)
  - ``childCount``= ``node.child_degree``
  - ``id``        = ``node.node_id`` (leaves only)
  - leaf/module discrimination = ``node.is_leaf``; the root (``node.depth``
    == 0, ``path == ()``) is excluded from ``modules``.
* metadata is fed via ``im.set_meta_data({node_id: category, ...})`` before
  ``im.run()``; the rate goes through the ``--meta-data-rate`` flag.
"""

import json
import math
import random
import sys
from collections import Counter
from pathlib import Path

from infomap import Infomap

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURES_DIR = REPO_ROOT / "Tests" / "InfomapKitTests" / "Fixtures"

BASE_FLAGS = "--silent --seed 42 --num-trials 10"

PATH_NOTE = (
    "node.path is the python tuple exactly as infomap 2.15.1 reports it: "
    "1-based child indices from the root, and for leaf NODES the last "
    "component is the leaf's position within its leaf module (drop the last "
    "component to get the leaf-module path). modules[] lists every non-leaf "
    "tree node at depth >= 1 in depth-first order; the root is excluded. "
    "In bipartite runs the engine reports flow 0.0 for feature (entity) nodes."
)


# --- Networks ---------------------------------------------------------------

def toy_network():
    """The 16-node toy from SpecStageTests.toyNetwork(), same link order."""
    links = []
    for episode in range(4):
        for entity in range(8, 12):
            links.append((episode, entity, 1.0))
    for episode in range(4, 8):
        for entity in range(12, 16):
            links.append((episode, entity, 1.0))
    links.append((0, 13, 0.3))
    return 8, links


def planted8_network(seed=42):
    """8 planted groups x 2 planted sub-communities, hub-penalized bipartite.

    Hyperedges (episodes) are primary nodes 0..127 (16 per group, 8 per
    sub-community); entities are feature nodes 128..191 (8 per group, 4 per
    sub-community). Each hyperedge draws 3 entities from its own
    sub-community (seeded rng.sample). The first 2 hyperedges of each
    sub-community additionally touch one sibling-sub-community entity
    (within-group glue), and the last hyperedge of each group touches the
    first entity of the next group (ring bridge -> connected graph).
    Link weight = 1/log2(1 + deg(entity)), deg over all incidences.
    """
    GROUPS = 8
    SUB_ENTITIES = 4     # entities per sub-community
    SUB_EDGES = 8        # hyperedges per sub-community
    PER_EDGE = 3         # entities sampled per hyperedge
    GLUE = 2             # within-group cross-sub incidences per sub-community

    rng = random.Random(seed)
    edges_per_group = 2 * SUB_EDGES
    n_edges = GROUPS * edges_per_group          # 128: bipartite start id
    ents_per_group = 2 * SUB_ENTITIES

    incidences = []
    for g in range(GROUPS):
        base_ent = n_edges + g * ents_per_group
        subs = [
            [base_ent + j for j in range(SUB_ENTITIES)],
            [base_ent + SUB_ENTITIES + j for j in range(SUB_ENTITIES)],
        ]
        for s in range(2):
            for h in range(SUB_EDGES):
                edge = g * edges_per_group + s * SUB_EDGES + h
                for e in rng.sample(subs[s], PER_EDGE):
                    incidences.append((edge, e))
            for c in range(GLUE):
                edge = g * edges_per_group + s * SUB_EDGES + c
                incidences.append((edge, subs[1 - s][c % SUB_ENTITIES]))
    for g in range(GROUPS):
        edge = g * edges_per_group + edges_per_group - 1
        entity = n_edges + ((g + 1) % GROUPS) * ents_per_group
        incidences.append((edge, entity))

    deg = Counter(e for _, e in incidences)
    links = [(h, e, 1.0 / math.log2(1 + deg[e])) for h, e in incidences]
    return n_edges, links


def directed_rings_network():
    """3 directed 10-node rings with i->i+2 chords, weakly bridged."""
    links = []
    for ring in range(3):
        base = ring * 10
        for i in range(10):
            links.append((base + i, base + (i + 1) % 10, 1.0))
        for i in range(10):
            links.append((base + i, base + (i + 2) % 10, 0.5))
    for u, v in ((0, 10), (10, 20), (20, 0), (5, 15), (15, 25), (25, 5)):
        links.append((u, v, 0.25))
    return links


# --- Engine run -> fixture dict --------------------------------------------

def run_fixture(name, flags, links, bipartite_start_id=None, meta=None):
    im = Infomap(flags)
    if bipartite_start_id is not None:
        im.bipartite_start_id = bipartite_start_id
    for source, target, weight in links:
        im.add_link(source, target, weight)
    if meta is not None:
        im.set_meta_data(meta)
    im.run()

    nodes = []
    modules = []
    for node in im.tree:                      # depth-first from the root
        if node.depth == 0:
            continue                          # root is excluded from modules
        if node.is_leaf:
            nodes.append({
                "id": node.node_id,
                "path": list(node.path),
                "flow": node.data.flow,
            })
        else:
            modules.append({
                "path": list(node.path),
                "flow": node.data.flow,
                "enterFlow": node.data.enter_flow,
                "exitFlow": node.data.exit_flow,
                "childCount": node.child_degree,
            })

    return {
        "name": name,
        "flags": flags,
        "notes": PATH_NOTE,
        "network": {
            "bipartiteStartId": bipartite_start_id,
            "links": [[s, t, w] for s, t, w in links],
            "meta": {str(k): v for k, v in meta.items()} if meta else None,
        },
        "expected": {
            "codelength": im.codelength,
            "oneLevelCodelength": im.one_level_codelength,
            "relativeCodelengthSavings": im.relative_codelength_savings,
            "numLevels": im.num_levels,
            "numTopModules": im.num_top_modules,
            "numLeafModules": im.num_leaf_modules,
            "nodes": nodes,
            "modules": modules,
        },
    }


def main():
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)

    toy_start, toy_links = toy_network()
    p8_start, p8_links = planted8_network()
    d_links = directed_rings_network()

    # Two categories aligned with the toy's two planted groups.
    toy_meta = {i: (0 if i < 4 else 1) for i in range(8)}
    toy_meta.update({i: (0 if i < 12 else 1) for i in range(8, 16)})

    fixtures = [
        run_fixture("toy-multilevel", BASE_FLAGS, toy_links,
                    bipartite_start_id=toy_start),
        run_fixture("planted8-multilevel", BASE_FLAGS, p8_links,
                    bipartite_start_id=p8_start),
        # 50 trials, not 10: at 10 the flat search stops in a slightly worse
        # local optimum (codelength 4.29935 vs 4.29882) whose identity is
        # platform-sensitive — macOS/pip and Linux/libstdc++ pick different
        # near-ties. At 50 trials every platform reaches the settled optimum.
        run_fixture("planted8-twolevel",
                    "--silent --seed 42 --num-trials 50 --two-level",
                    p8_links, bipartite_start_id=p8_start),
        run_fixture("directed-multilevel", BASE_FLAGS + " --flow-model directed",
                    d_links),
        # iliasaz/infomap#1: --regularized + bipartite declaration is broken,
        # so the regularized fixture runs UNIPARTITE (same links, no start id).
        run_fixture("planted8-regularized",
                    BASE_FLAGS + " --regularized --regularization-strength 0.3",
                    p8_links),
        run_fixture("toy-meta", BASE_FLAGS + " --meta-data-rate 1.0",
                    toy_links, bipartite_start_id=toy_start, meta=toy_meta),
    ]

    total = 0
    for fixture in fixtures:
        path = FIXTURES_DIR / f"{fixture['name']}.json"
        payload = json.dumps(fixture, indent=1) + "\n"
        path.write_text(payload)
        total += len(payload)
        e = fixture["expected"]
        print(
            f"{path.name}: top={e['numTopModules']} leaf={e['numLeafModules']} "
            f"levels={e['numLevels']} savings={e['relativeCodelengthSavings']:.4f} "
            f"nodes={len(e['nodes'])} modules={len(e['modules'])} "
            f"({len(payload)} bytes)"
        )
    print(f"total {total} bytes -> {FIXTURES_DIR}")


if __name__ == "__main__":
    sys.exit(main())
