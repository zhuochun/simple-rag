from __future__ import annotations

import time
from typing import Any

import numpy as np

from .labels import map_snippet


def build_payload(
    notes: list[dict[str, Any]],
    vector_dim: int,
    assignments: list[int],
    semantic_points: np.ndarray,
    display_points: np.ndarray,
    node_metrics: dict[int, dict[str, float | int]],
    density_weights: dict[int, float],
    edges: list[dict[str, Any]],
    centers: dict[int, dict[str, float | int]],
    profiles: list[dict[str, Any]],
    labels: dict[int, dict[str, Any]],
    terrain: dict[str, Any] | None,
    layout_meta: dict[str, Any],
    width: int,
    height: int,
    peak_anchors: dict[int, list[dict[str, Any]]] | None = None,
    anchor_labels: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    community_to_cluster = {profile["communityId"]: profile["clusterId"] for profile in profiles}
    cluster_order = {profile["communityId"]: idx for idx, profile in enumerate(profiles, start=1)}
    clusters = []
    for idx, profile in enumerate(profiles, start=1):
        cid = int(profile["communityId"])
        label = labels.get(idx, {})
        member_indices = [i for i, value in enumerate(assignments) if value == cid]
        pts = display_points[member_indices] if member_indices else np.zeros((1, 2))
        anchors = list((peak_anchors or {}).get(cid) or [])
        if not anchors:
            peak_x, peak_y = cluster_density_peak(display_points, member_indices, density_weights)
            anchors = [{"x": peak_x, "y": peak_y, "rank": 1, "density": 0.0}]
        else:
            peak_x, peak_y = float(anchors[0]["x"]), float(anchors[0]["y"])
        neighbors = [
            {"clusterId": community_to_cluster.get(item["communityId"], f"mountain-{item['communityId']}"), "weight": round(float(item["weight"]), 4)}
            for item in profile.get("neighborClusters", [])
        ]
        label_anchors = []
        for pos, anchor in enumerate(anchors):
            rank = int(anchor.get("rank") or pos + 1)
            anchor_label = (anchor_labels or {}).get(f"{cid}:{rank}", {})
            label_anchors.append({
                "x": round(float(anchor["x"]), 2),
                "y": round(float(anchor["y"]), 2),
                "rank": rank,
                "density": round(float(anchor.get("density") or 0.0), 4),
                "primaryLabel": anchor_label.get("primaryLabel", ""),
                "subtitle": anchor_label.get("subtitle", ""),
                "keywordChips": anchor_label.get("keywordChips", [])[:3],
                "labelSource": anchor_label.get("labelSource", "fallback"),
            })
        clusters.append({
            "id": profile["clusterId"],
            "communityId": cid,
            "label": label.get("primaryLabel", profile["clusterId"]),
            "primaryLabel": label.get("primaryLabel", profile["clusterId"]),
            "subtitle": label.get("subtitle", ""),
            "keywordChips": label.get("keywordChips", [])[:3],
            "labelSource": label.get("labelSource", "fallback"),
            "centerX": round(float(centers[cid]["x"]), 2),
            "centerY": round(float(centers[cid]["y"]), 2),
            "peakX": round(float(peak_x), 2),
            "peakY": round(float(peak_y), 2),
            "labelAnchors": label_anchors,
            "spreadX": round(float(np.std(pts[:, 0]) + 36.0), 2),
            "spreadY": round(float(np.std(pts[:, 1]) + 36.0), 2),
            "noteCount": len(member_indices),
            "neighbors": neighbors,
        })
    note_payload = []
    for idx, note in enumerate(notes):
        cid = int(assignments[idx])
        metric = node_metrics[idx]
        note_payload.append({
            "id": f"{note['lookup']}::{note['path']}#{note['chunk']}",
            "index": idx,
            "lookup": note["lookup"],
            "path": note["path"],
            "chunk": note["chunk"],
            "hash": note["hash"],
            "title": note["title"],
            "url": note["url"],
            "snippet": map_snippet(note.get("text", "")),
            "communityId": cid,
            "clusterId": community_to_cluster[cid],
            "semanticX": round(float(semantic_points[idx, 0]), 6),
            "semanticY": round(float(semantic_points[idx, 1]), 6),
            "x": round(float(display_points[idx, 0]), 2),
            "y": round(float(display_points[idx, 1]), 2),
            "degree": int(metric["degree"]),
            "internalWeight": round(float(metric["internalWeight"]), 4),
            "externalWeight": round(float(metric["externalWeight"]), 4),
            "bridgeScore": round(float(metric["bridgeScore"]), 4),
            "densityWeight": round(float(density_weights.get(idx, 1.0)), 4),
        })
    edge_payload = []
    for edge in edges:
        s = int(edge["source"])
        t = int(edge["target"])
        same = assignments[s] == assignments[t]
        edge_payload.append({
            "sourceIndex": s,
            "targetIndex": t,
            "weight": round(float(edge["weight"]), 4),
            "sameCommunity": same,
            "bridge": not same,
            "mutual": bool(edge.get("mutual")),
        })
    payload = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "generator": "simple_rag_map_v2",
        "noteCount": len(note_payload),
        "vectorDim": vector_dim,
        "width": width,
        "height": height,
        "layout": layout_meta,
        "clusters": clusters,
        "notes": note_payload,
        "edges": edge_payload,
    }
    if terrain is not None:
        payload["terrain"] = terrain
    return payload


def cluster_density_peak(
    points: np.ndarray,
    member_indices: list[int],
    density_weights: dict[int, float],
    *,
    sigma: float = 54.0,
) -> tuple[float, float]:
    if not member_indices:
        return 0.0, 0.0
    cluster_points = points[member_indices]
    if len(member_indices) == 1:
        return float(cluster_points[0, 0]), float(cluster_points[0, 1])

    weights = np.asarray([float(density_weights.get(idx, 1.0)) for idx in member_indices], dtype=float)
    sigma2 = 2.0 * sigma * sigma
    scores = np.zeros(len(member_indices), dtype=float)
    # Evaluate cluster-local KDE at note coordinates. Chunking avoids a large temporary matrix for bigger clusters.
    for start in range(0, len(member_indices), 384):
        candidates = cluster_points[start : start + 384]
        dx = candidates[:, None, 0] - cluster_points[None, :, 0]
        dy = candidates[:, None, 1] - cluster_points[None, :, 1]
        scores[start : start + len(candidates)] = np.sum(np.exp(-((dx * dx) + (dy * dy)) / sigma2) * weights[None, :], axis=1)

    best = int(np.argmax(scores))
    best_point = cluster_points[best]
    local_radius2 = (sigma * 0.9) ** 2
    dx = cluster_points[:, 0] - best_point[0]
    dy = cluster_points[:, 1] - best_point[1]
    near = ((dx * dx) + (dy * dy)) <= local_radius2
    if not np.any(near):
        return float(best_point[0]), float(best_point[1])
    local_scores = scores[near]
    local_points = cluster_points[near]
    local_weights = np.maximum(local_scores - float(np.min(local_scores)), 1e-6)
    peak = np.average(local_points, axis=0, weights=local_weights)
    return float(peak[0]), float(peak[1])


def json_dumps(data: Any) -> str:
    try:
        import orjson

        return orjson.dumps(data, option=orjson.OPT_INDENT_2 | orjson.OPT_APPEND_NEWLINE).decode("utf-8")
    except Exception:
        import json

        return json.dumps(data, ensure_ascii=False, indent=2) + "\n"
