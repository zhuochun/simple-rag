from __future__ import annotations

import hashlib
import math
from typing import Any

import igraph as ig
import numpy as np
from sklearn.decomposition import PCA

from .communities import members_by_community
from .config import CartographyConfig, SemanticLayoutConfig
from .graph import community_graph


WIDTH = 3200
HEIGHT = 2200
MARGIN = 140
CONTENT_PADDING = 420


def semantic_layout(embeddings: np.ndarray, config: SemanticLayoutConfig) -> dict[str, Any]:
    if embeddings.shape[0] == 1:
        raw = np.asarray([[0.0, 0.0]], dtype=float)
        return {"raw": raw, "normalized": raw.copy(), "method": "single_point", "fallbackReason": "single note corpus"}

    raw_method = config.method
    try:
        if raw_method == "umap" and embeddings.shape[0] > 3:
            import umap

            reducer = umap.UMAP(
                n_components=2,
                n_neighbors=min(config.n_neighbors, max(2, embeddings.shape[0] - 1)),
                min_dist=config.min_dist,
                metric=config.metric,
                random_state=config.random_state,
            )
            raw = reducer.fit_transform(embeddings)
            method = "umap"
        else:
            raise ValueError("UMAP skipped for tiny corpus")
    except Exception as exc:
        components = min(2, embeddings.shape[0], embeddings.shape[1])
        pca_raw = PCA(n_components=components, random_state=config.random_state).fit_transform(embeddings)
        if components == 1:
            raw = np.column_stack([pca_raw[:, 0], np.zeros(embeddings.shape[0])])
        else:
            raw = pca_raw
        method = "pca_fallback"
        raw_method = f"{raw_method}: {exc.__class__.__name__}: {exc}"
    normalized = _normalize_points(raw, -1.0, 1.0, -1.0, 1.0)
    return {"raw": raw, "normalized": normalized, "method": method, "fallbackReason": raw_method if method != "umap" else None}


def community_centers(assignments: list[int], edges: list[dict[str, Any]], seed: int, separation: float) -> dict[int, dict[str, float | int]]:
    communities = sorted(set(assignments))
    index = {cid: idx for idx, cid in enumerate(communities)}
    if len(communities) == 1:
        return {communities[0]: {"x": WIDTH / 2, "y": HEIGHT / 2, "size": len(assignments), "neighborWeight": 0.0}}
    weights = community_graph(edges, assignments)
    graph_edges = [(index[a], index[b]) for (a, b) in weights]
    graph = ig.Graph(n=len(communities), edges=graph_edges, directed=False)
    graph.es["weight"] = [weights[(a, b)] for (a, b) in weights]
    initial = _initial_center_coords(len(communities), seed)
    if graph.ecount() == 0:
        coords = initial
    else:
        coords = graph.layout_fruchterman_reingold(weights="weight", niter=900, seed=initial).coords
    arr = np.asarray(coords, dtype=float)
    arr = _normalize_points(arr, MARGIN, WIDTH - MARGIN, MARGIN, HEIGHT - MARGIN)
    center_x = WIDTH / 2
    center_y = HEIGHT / 2
    arr[:, 0] = center_x + (arr[:, 0] - center_x) * separation
    arr[:, 1] = center_y + (arr[:, 1] - center_y) * separation
    sizes = {cid: assignments.count(cid) for cid in communities}
    neighbor = {cid: 0.0 for cid in communities}
    for (a, b), weight in weights.items():
        neighbor[a] += float(weight)
        neighbor[b] += float(weight)
    return {
        cid: {"x": float(arr[index[cid], 0]), "y": float(arr[index[cid], 1]), "size": int(sizes[cid]), "neighborWeight": float(neighbor[cid])}
        for cid in communities
    }


def mountain_layout(
    semantic_points: np.ndarray,
    assignments: list[int],
    edges: list[dict[str, Any]],
    node_metrics: dict[int, dict[str, float | int]],
    centers: dict[int, dict[str, float | int]],
    config: CartographyConfig,
    seed: int,
) -> dict[str, Any]:
    members = members_by_community(assignments)
    community_neighbors = _community_neighbor_centers(assignments, edges, centers)
    points = np.zeros((len(assignments), 2), dtype=float)
    density_weight: dict[int, float] = {}
    for cid, idxs in members.items():
        center = centers[cid]
        cx = float(center["x"])
        cy = float(center["y"])
        size = len(idxs)
        radius = 42.0 + math.sqrt(size) * 18.0
        internal_values = [float(node_metrics[idx]["internalWeight"]) for idx in idxs]
        max_internal = max(internal_values) if internal_values else 1.0
        local_sem = semantic_points[idxs]
        local_center = np.mean(local_sem, axis=0)
        for rank, idx in enumerate(sorted(idxs, key=lambda n: (-float(node_metrics[n]["internalWeight"]), float(node_metrics[n]["bridgeScore"]), n))):
            metric = node_metrics[idx]
            core = float(metric["internalWeight"]) / max(max_internal, 1e-9)
            bridge = float(metric["bridgeScore"])
            degree = float(metric["degree"])
            sem_vec = semantic_points[idx] - local_center
            angle = math.atan2(float(sem_vec[1]), float(sem_vec[0])) if np.linalg.norm(sem_vec) > 1e-9 else _stable_angle(seed, idx)
            jitter = _stable_noise(seed, idx)
            ring = (rank + 1) / max(size, 1)
            base_r = radius * (0.16 + (1.0 - core) * config.core_packing + ring * 0.42)
            base_r *= 1.0 + (jitter - 0.5) * 0.32 * config.mountain_shape_strength
            if degree <= 1:
                base_r *= config.foothill_spread
            x = cx + math.cos(angle) * base_r
            y = cy + math.sin(angle) * base_r * (0.76 + 0.3 * _stable_noise(seed + 17, idx))
            if bridge > 0.18 and cid in community_neighbors:
                bx, by = community_neighbors[cid]
                blend = min(config.bridge_blend, bridge)
                x = x * (1.0 - blend) + bx * blend
                y = y * (1.0 - blend) + by * blend
            points[idx, 0] = x
            points[idx, 1] = y
            density_weight[idx] = max(0.35, 0.72 + core * 1.2 + math.log1p(degree) * 0.08 - bridge * 0.55)
    return {"points": points, "densityWeight": density_weight}


def reframe_layout(points: np.ndarray, centers: dict[int, dict[str, float | int]], padding: float = CONTENT_PADDING) -> dict[str, Any]:
    center_points = np.asarray([[float(center["x"]), float(center["y"])] for center in centers.values()], dtype=float)
    all_points = np.vstack([points, center_points]) if len(center_points) else points
    min_x = float(np.min(all_points[:, 0]))
    min_y = float(np.min(all_points[:, 1]))
    max_x = float(np.max(all_points[:, 0]))
    max_y = float(np.max(all_points[:, 1]))
    shift_x = padding - min_x
    shift_y = padding - min_y
    framed = points.copy()
    framed[:, 0] += shift_x
    framed[:, 1] += shift_y
    framed_centers = {}
    for cid, center in centers.items():
        framed_centers[cid] = {
            **center,
            "x": float(center["x"]) + shift_x,
            "y": float(center["y"]) + shift_y,
        }
    width = int(math.ceil((max_x - min_x) + (padding * 2)))
    height = int(math.ceil((max_y - min_y) + (padding * 2)))
    return {
        "points": framed,
        "centers": framed_centers,
        "width": max(width, 1200),
        "height": max(height, 900),
        "bounds": {
            "minX": min_x,
            "minY": min_y,
            "maxX": max_x,
            "maxY": max_y,
            "shiftX": shift_x,
            "shiftY": shift_y,
            "padding": padding,
        },
    }


def _community_neighbor_centers(assignments: list[int], edges: list[dict[str, Any]], centers: dict[int, dict[str, float | int]]) -> dict[int, tuple[float, float]]:
    sums: dict[int, list[float]] = {}
    for (a, b), weight in community_graph(edges, assignments).items():
        for cid, other in ((a, b), (b, a)):
            item = sums.setdefault(cid, [0.0, 0.0, 0.0])
            item[0] += float(centers[other]["x"]) * weight
            item[1] += float(centers[other]["y"]) * weight
            item[2] += weight
    return {cid: (values[0] / values[2], values[1] / values[2]) for cid, values in sums.items() if values[2] > 0}


def _normalize_points(points: np.ndarray, min_x: float, max_x: float, min_y: float, max_y: float) -> np.ndarray:
    arr = np.asarray(points, dtype=float)
    if arr.shape[0] == 1:
        return np.asarray([[(min_x + max_x) / 2.0, (min_y + max_y) / 2.0]])
    out = np.zeros_like(arr, dtype=float)
    for axis, lo, hi in ((0, min_x, max_x), (1, min_y, max_y)):
        col = arr[:, axis]
        span = float(np.max(col) - np.min(col))
        if abs(span) < 1e-12:
            out[:, axis] = (lo + hi) / 2.0
        else:
            out[:, axis] = lo + ((col - np.min(col)) / span) * (hi - lo)
    return out


def _initial_center_coords(count: int, seed: int) -> list[list[float]]:
    if count <= 0:
        return []
    step = math.tau / count
    offset = _stable_noise(seed, count) * math.tau
    return [[math.cos(offset + i * step), math.sin(offset + i * step)] for i in range(count)]


def _stable_angle(seed: int, idx: int) -> float:
    return _stable_noise(seed, idx) * math.tau


def _stable_noise(seed: int, idx: int) -> float:
    digest = hashlib.sha256(f"{seed}:{idx}".encode("utf-8")).hexdigest()
    return int(digest[:12], 16) / float(0xFFFFFFFFFFFF)
