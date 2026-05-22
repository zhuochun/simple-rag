from __future__ import annotations

from collections import defaultdict, deque
from typing import Any

import numpy as np
from sklearn.neighbors import NearestNeighbors


def build_knn_graph(embeddings: np.ndarray, k: int) -> dict[str, Any]:
    n = int(embeddings.shape[0])
    if n <= 1:
        return {"directed": [], "edges": [], "adjacency": [[] for _ in range(n)], "stats": _stats(n, [], [])}
    k = min(max(1, k), n - 1)
    nn = NearestNeighbors(n_neighbors=k + 1, metric="cosine")
    nn.fit(embeddings)
    distances, indices = nn.kneighbors(embeddings)
    directed = []
    directed_lookup: dict[tuple[int, int], dict[str, Any]] = {}
    for source in range(n):
        for dist, target in zip(distances[source], indices[source]):
            target = int(target)
            if target == source:
                continue
            similarity = max(0.0, min(1.0, 1.0 - float(dist)))
            edge = {"source": source, "target": target, "similarity": similarity, "distance": float(dist)}
            directed.append(edge)
            directed_lookup[(source, target)] = edge
    edges = _symmetrize(directed_lookup)
    adjacency = [[] for _ in range(n)]
    for edge in edges:
        s = int(edge["source"])
        t = int(edge["target"])
        w = float(edge["weight"])
        adjacency[s].append((t, w))
        adjacency[t].append((s, w))
    return {"directed": directed, "edges": edges, "adjacency": adjacency, "stats": _stats(n, directed, edges)}


def _symmetrize(directed: dict[tuple[int, int], dict[str, Any]]) -> list[dict[str, Any]]:
    out = []
    seen = set()
    for (source, target), edge in directed.items():
        left, right = (source, target) if source < target else (target, source)
        if (left, right) in seen:
            continue
        seen.add((left, right))
        reverse = directed.get((target, source))
        mutual = reverse is not None
        weight = max(float(edge["similarity"]), float(reverse["similarity"]) if reverse else 0.0)
        if mutual:
            weight *= 1.15
        weight = max(0.0, min(1.0, weight))
        if mutual or weight >= 0.05:
            out.append({"source": left, "target": right, "weight": weight, "mutual": mutual})
    return out


def node_edge_metrics(node_count: int, edges: list[dict[str, Any]], assignments: list[int]) -> dict[int, dict[str, float | int]]:
    metrics: dict[int, dict[str, float | int]] = {
        idx: {"degree": 0, "internalWeight": 0.0, "externalWeight": 0.0, "bridgeScore": 0.0}
        for idx in range(node_count)
    }
    for edge in edges:
        s = int(edge["source"])
        t = int(edge["target"])
        w = float(edge["weight"])
        same = assignments[s] == assignments[t]
        for a, b in ((s, t), (t, s)):
            metrics[a]["degree"] = int(metrics[a]["degree"]) + 1
            key = "internalWeight" if same else "externalWeight"
            metrics[a][key] = float(metrics[a][key]) + w
    for values in metrics.values():
        internal = float(values["internalWeight"])
        external = float(values["externalWeight"])
        total = internal + external
        values["bridgeScore"] = external / total if total > 0 else 0.0
    return metrics


def community_graph(edges: list[dict[str, Any]], assignments: list[int]) -> dict[tuple[int, int], float]:
    weights: dict[tuple[int, int], float] = defaultdict(float)
    for edge in edges:
        ca = assignments[int(edge["source"])]
        cb = assignments[int(edge["target"])]
        if ca == cb:
            continue
        key = (ca, cb) if ca < cb else (cb, ca)
        weights[key] += float(edge["weight"])
    return dict(weights)


def _stats(node_count: int, directed: list[dict[str, Any]], edges: list[dict[str, Any]]) -> dict[str, Any]:
    degrees = [0] * node_count
    for edge in edges:
        degrees[int(edge["source"])] += 1
        degrees[int(edge["target"])] += 1
    components = _connected_components(node_count, edges)
    weights = [float(edge["weight"]) for edge in edges]
    mutual = sum(1 for edge in edges if edge.get("mutual"))
    return {
        "nodeCount": node_count,
        "directedEdgeCount": len(directed),
        "undirectedEdgeCount": len(edges),
        "mutualEdgeRatio": mutual / len(edges) if edges else 0.0,
        "averageDegree": float(sum(degrees) / node_count) if node_count else 0.0,
        "connectedComponents": len(components),
        "componentSizes": sorted((len(c) for c in components), reverse=True),
        "edgeWeightDistribution": _distribution(weights),
    }


def _connected_components(node_count: int, edges: list[dict[str, Any]]) -> list[list[int]]:
    adj = [[] for _ in range(node_count)]
    for edge in edges:
        s = int(edge["source"])
        t = int(edge["target"])
        adj[s].append(t)
        adj[t].append(s)
    seen = [False] * node_count
    comps = []
    for start in range(node_count):
        if seen[start]:
            continue
        q = deque([start])
        seen[start] = True
        comp = []
        while q:
            node = q.popleft()
            comp.append(node)
            for nxt in adj[node]:
                if not seen[nxt]:
                    seen[nxt] = True
                    q.append(nxt)
        comps.append(comp)
    return comps


def _distribution(values: list[float]) -> dict[str, float]:
    if not values:
        return {"min": 0.0, "p25": 0.0, "median": 0.0, "p75": 0.0, "max": 0.0}
    arr = np.asarray(values, dtype=float)
    return {
        "min": float(np.min(arr)),
        "p25": float(np.quantile(arr, 0.25)),
        "median": float(np.quantile(arr, 0.5)),
        "p75": float(np.quantile(arr, 0.75)),
        "max": float(np.max(arr)),
    }
