from __future__ import annotations

from typing import Any

import numpy as np


def build_debug(
    embedding_stats: dict[str, Any],
    graph_stats: dict[str, Any],
    community_stats: dict[str, Any],
    semantic_meta: dict[str, Any],
    centers: dict[int, dict[str, float | int]],
    terrain: dict[str, Any] | None,
    profiles: list[dict[str, Any]],
    node_metrics: dict[int, dict[str, float | int]],
    layout_params: dict[str, Any],
) -> dict[str, Any]:
    bridge_scores = [float(item["bridgeScore"]) for item in node_metrics.values()]
    return {
        "embedding": embedding_stats,
        "graph": graph_stats,
        "communities": community_stats,
        "bridgeScoreHistogram": _histogram(bridge_scores),
        "semanticLayout": semantic_meta,
        "communityCenters": {str(k): v for k, v in centers.items()},
        "mountainLayout": layout_params,
        "terrain": {
            "cellSize": terrain.get("cellSize"),
            "sigma": terrain.get("sigma"),
            "levelCount": len(terrain.get("levels") or []),
            "maxDensity": terrain.get("maxDensity"),
        } if terrain else None,
        "labelProfileSamples": profiles[:8],
        "warnings": warnings(graph_stats, community_stats, bridge_scores, terrain),
    }


def warnings(graph_stats: dict[str, Any], community_stats: dict[str, Any], bridge_scores: list[float], terrain: dict[str, Any] | None) -> list[str]:
    out = []
    if graph_stats.get("mutualEdgeRatio", 1.0) < 0.25:
        out.append("low mutual edge ratio")
    if graph_stats.get("connectedComponents", 1) > 5:
        out.append("high disconnected component count")
    sizes = community_stats.get("sizes") or []
    if sizes:
        if sizes[0] / max(sum(sizes), 1) > 0.65:
            out.append("one giant dominant community")
        if sum(1 for size in sizes if size < 12) > max(4, len(sizes) // 3):
            out.append("too many small communities")
    if bridge_scores and sum(1 for score in bridge_scores if score > 0.45) / len(bridge_scores) > 0.3:
        out.append("too many bridge notes")
    if terrain and len(terrain.get("levels") or []) < 4:
        out.append("terrain contours too sparse")
    return out


def _histogram(values: list[float], bins: int = 10) -> dict[str, Any]:
    if not values:
        return {"bins": [], "counts": []}
    counts, edges = np.histogram(np.asarray(values, dtype=float), bins=bins, range=(0.0, 1.0))
    return {"bins": [round(float(edge), 3) for edge in edges.tolist()], "counts": [int(v) for v in counts.tolist()]}
