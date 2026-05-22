from __future__ import annotations

from collections import Counter, defaultdict
from typing import Any

import igraph as ig
import leidenalg


def detect_communities(node_count: int, edges: list[dict[str, Any]], *, resolution: float, min_size: int, seed: int) -> dict[str, Any]:
    graph = ig.Graph(n=node_count, edges=[(int(e["source"]), int(e["target"])) for e in edges], directed=False)
    graph.es["weight"] = [float(e["weight"]) for e in edges]
    partition = leidenalg.find_partition(
        graph,
        leidenalg.RBConfigurationVertexPartition,
        weights="weight",
        resolution_parameter=resolution,
        seed=seed,
    )
    assignments = [int(cid) for cid in partition.membership]
    assignments = _merge_small(assignments, edges, min_size)
    assignments = _reindex_by_size(assignments)
    stats = community_stats(assignments, edges)
    return {"assignments": assignments, "stats": stats, "method": "leiden_rb_configuration"}


def community_stats(assignments: list[int], edges: list[dict[str, Any]]) -> dict[str, Any]:
    sizes = Counter(assignments)
    internal = defaultdict(float)
    external = defaultdict(float)
    neighbor_weights: dict[int, dict[int, float]] = defaultdict(lambda: defaultdict(float))
    for edge in edges:
        s = int(edge["source"])
        t = int(edge["target"])
        w = float(edge["weight"])
        ca = assignments[s]
        cb = assignments[t]
        if ca == cb:
            internal[ca] += w
        else:
            external[ca] += w
            external[cb] += w
            neighbor_weights[ca][cb] += w
            neighbor_weights[cb][ca] += w
    items = []
    for cid, size in sorted(sizes.items(), key=lambda item: (-item[1], item[0])):
        iw = float(internal[cid])
        ew = float(external[cid])
        items.append({
            "communityId": int(cid),
            "size": int(size),
            "internalWeight": iw,
            "externalWeight": ew,
            "bridgeScore": ew / (iw + ew) if iw + ew > 0 else 0.0,
            "nearestNeighborCommunities": [
                {"communityId": int(nid), "weight": float(weight)}
                for nid, weight in sorted(neighbor_weights[cid].items(), key=lambda item: -item[1])[:8]
            ],
        })
    return {
        "communityCount": len(sizes),
        "sizes": [item["size"] for item in items],
        "communities": items,
    }


def members_by_community(assignments: list[int]) -> dict[int, list[int]]:
    members: dict[int, list[int]] = defaultdict(list)
    for idx, cid in enumerate(assignments):
        members[int(cid)].append(idx)
    return dict(members)


def _merge_small(assignments: list[int], edges: list[dict[str, Any]], min_size: int) -> list[int]:
    out = list(assignments)
    while True:
        sizes = Counter(out)
        small = [cid for cid, size in sizes.items() if size < min_size and len(sizes) > 1]
        if not small:
            return out
        changed = False
        for cid in small:
            neighbor_score: dict[int, float] = defaultdict(float)
            for edge in edges:
                s = int(edge["source"])
                t = int(edge["target"])
                cs = out[s]
                ct = out[t]
                if cs == ct:
                    continue
                if cs == cid:
                    neighbor_score[ct] += float(edge["weight"])
                elif ct == cid:
                    neighbor_score[cs] += float(edge["weight"])
            if not neighbor_score:
                target = max((other for other in sizes if other != cid), key=lambda other: sizes[other])
            else:
                target = max(neighbor_score, key=neighbor_score.get)
            for idx, value in enumerate(out):
                if value == cid:
                    out[idx] = target
                    changed = True
        if not changed:
            return out


def _reindex_by_size(assignments: list[int]) -> list[int]:
    sizes = Counter(assignments)
    ordered = [cid for cid, _ in sorted(sizes.items(), key=lambda item: (-item[1], item[0]))]
    remap = {cid: idx + 1 for idx, cid in enumerate(ordered)}
    return [remap[cid] for cid in assignments]
