from __future__ import annotations

from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path, PurePath
import random
import sqlite3
import time
from typing import Any

from .config import Config, PathConfig, map_value
from .graph import (
    COMMUNITY_GRAVITY,
    CROSS_COMMUNITY_ATTRACTION,
    CROSS_COMMUNITY_EDGE_IDEAL,
    MAP_CROSS_COMMUNITY_EDGES_PER_NODE,
    SAME_COMMUNITY_ATTRACTION,
    SAME_COMMUNITY_EDGE_IDEAL,
    build_knn_edges,
    build_members_from_assignments,
    detect_communities_weighted_local_moving,
    dot,
    graph_from_edges,
    layout_graph_force,
    node_graph_debug,
    retain_layout_edges,
    safe_normalize,
    shape_points_as_mountains,
    symmetrize_knn_edges,
)
from .labels import (
    Labeler,
    MAX_LABEL_SNIPPETS,
    fallback_label,
    keywords_from_snippets,
    label_excerpt,
    label_key,
    map_snippet,
)
MAP_WIDTH = 2600
MAP_HEIGHT = 1700
MAP_MARGIN = 140
MIN_CLUSTER_COUNT = 1
MAX_CLUSTER_COUNT = 18
MIN_CLUSTER_SIZE = 3
KMEANS_MAX_ITER = 24
KMEANS_EPSILON = 1e-5
MAP_LAYOUT_DEFAULT = "graph"
MAP_KNN_K_DEFAULT = 30
MAP_COMMUNITY_MIN_SIZE_DEFAULT = 8
MAP_GRAPH_EDGE_MIN_WEIGHT_DEFAULT = 0.0
MAP_LAYOUT_ITERATIONS_DEFAULT = 650
NODE_LAYOUT_ITERATION_MAX = 3000
NODE_LAYOUT_MIN_ITERATIONS = 50
MAP_MAX_GRAPH_COMMUNITIES = 160


def map_layout_requested(config: Config) -> str | None:
    raw = map_value(config, "layout")
    if raw is None or str(raw).strip() == "":
        return None
    value = str(raw).strip().lower()
    if value not in {"graph", "kmeans"}:
        raise ValueError(f'Invalid map.layout "{raw}". Expected "graph" or "kmeans"')
    return value


def graph_layout_enabled(config: Config) -> bool:
    requested = map_layout_requested(config)
    return requested == "graph" if requested is not None else True


def map_integer_config(config: Config, key: str, *, default: int, min_value: int, max_value: int) -> int:
    raw = map_value(config, key)
    value = default if raw is None else int(raw)
    if value < min_value:
        raise ValueError(f"Invalid map.{key}: must be >= {min_value}")
    return min(value, max_value)


def map_float_config(config: Config, key: str, *, default: float) -> float:
    raw = map_value(config, key)
    return default if raw is None else float(raw)


def graph_knn_k(config: Config, note_count: int) -> int:
    k = map_integer_config(config, "knnK", default=MAP_KNN_K_DEFAULT, min_value=3, max_value=10_000)
    return min(k, max(note_count - 1, 1))


def graph_community_min_size(config: Config) -> int:
    return map_integer_config(config, "communityMinSize", default=MAP_COMMUNITY_MIN_SIZE_DEFAULT, min_value=2, max_value=10_000)


def graph_edge_min_weight(config: Config) -> float:
    value = map_float_config(config, "graphEdgeMinWeight", default=MAP_GRAPH_EDGE_MIN_WEIGHT_DEFAULT)
    if value < 0.0:
        raise ValueError("Invalid map.graphEdgeMinWeight: must be >= 0.0")
    return min(value, 1.0)


def map_layout_iterations(config: Config) -> int:
    return map_integer_config(
        config,
        "layoutIterations",
        default=MAP_LAYOUT_ITERATIONS_DEFAULT,
        min_value=NODE_LAYOUT_MIN_ITERATIONS,
        max_value=NODE_LAYOUT_ITERATION_MAX,
    )


def load_all_notes(paths: list[PathConfig]) -> list[dict[str, Any]]:
    all_notes: list[dict[str, Any]] = []
    for path_cfg in paths:
        notes = read_sqlite_path(path_cfg)
        print(f'Loaded {len(notes)} notes from "{path_cfg.name}"')
        all_notes.extend(notes)
    return all_notes


def safe_float_array(raw: Any) -> list[float]:
    arr = raw if isinstance(raw, list) else json.loads(str(raw))
    return [float(value) for value in arr]


def extract_id(file_path: str) -> str:
    parts = PurePath(file_path).parts
    if len(parts) < 2:
        return Path(file_path).name
    return str(PurePath(*parts[-2:])).replace("\\", "/")


def extract_url(file_path: str, url_prefix: str | None) -> str:
    if url_prefix is not None:
        return f"{url_prefix}{Path(file_path).stem}"
    return f"file://{file_path}"


def read_sqlite_path(path_cfg: PathConfig) -> list[dict[str, Any]]:
    notes: list[dict[str, Any]] = []
    conn = sqlite3.connect(str(path_cfg.db_file))
    conn.row_factory = sqlite3.Row
    try:
        quoted_table = '"' + str(path_cfg.db_table).replace('"', '""') + '"'
        for row in conn.execute(f"SELECT path, chunk, hash, embedding, bucket, text FROM {quoted_table}"):
            file_path = row["path"]
            chunk_idx = int(row["chunk"])
            text = row["text"]
            if text is None or not str(text).strip():
                continue
            notes.append(_note_from_row(path_cfg, row, file_path, chunk_idx, text, safe_float_array(row["embedding"])))
    finally:
        conn.close()
    return notes


def _note_from_row(path_cfg: PathConfig, row: Any, file_path: str, chunk_idx: int, text: str, embedding: list[float]) -> dict[str, Any]:
    return {
        "path": file_path,
        "chunk": chunk_idx,
        "hash": row["hash"],
        "lookup": path_cfg.name,
        "id": extract_id(file_path),
        "url": extract_url(file_path, path_cfg.url),
        "text": text,
        "embedding": embedding,
    }


def prepare_notes_for_map(notes: list[dict[str, Any]]) -> int:
    if not notes:
        raise RuntimeError("No notes available. Run run-index first.")
    vector_dim = None
    for idx, note in enumerate(notes):
        emb = note.get("embedding")
        if not emb:
            raise RuntimeError(f"Missing embedding for note index {idx} ({note['path']}#{note['chunk']})")
        vector_dim = vector_dim or len(emb)
        if len(emb) != vector_dim:
            raise RuntimeError(f"Embedding dimension mismatch: expected={vector_dim}, got={len(emb)}, note={note['path']}#{note['chunk']}")
        normalized = safe_normalize(emb)
        if normalized is None:
            raise RuntimeError(f"Zero-norm embedding at {note['path']}#{note['chunk']}")
        note["embedding"] = normalized
    return int(vector_dim)


def choose_anchor_indices(embeddings: list[list[float]]) -> tuple[int, int, int]:
    count = len(embeddings)
    if count == 1:
        return 0, 0, 0
    if count == 2:
        return 0, 1, 0
    a = 0
    b = max(range(count), key=lambda idx: 1.0 - dot(embeddings[a], embeddings[idx]))
    c = max(range(count), key=lambda idx: min(1.0 - dot(embeddings[a], embeddings[idx]), 1.0 - dot(embeddings[b], embeddings[idx])))
    return a, b, c


def normalize_to_canvas(values: list[float], min_px: float, max_px: float) -> list[float]:
    if not values:
        return []
    min_v = min(values)
    max_v = max(values)
    span = max_v - min_v
    if abs(span) < 1e-9:
        return [(min_px + max_px) / 2.0 for _ in values]
    return [min_px + ((value - min_v) / span) * (max_px - min_px) for value in values]


def desired_cluster_count(note_count: int) -> int:
    if note_count <= 30:
        return 1
    base = round(math.sqrt(note_count) / 2.2)
    return min(max(base, MIN_CLUSTER_COUNT), MAX_CLUSTER_COUNT, note_count)


def sq_dist(a: list[float], b: list[float]) -> float:
    dx = a[0] - b[0]
    dy = a[1] - b[1]
    return (dx * dx) + (dy * dy)


def kmeans_plus_plus(points: list[list[float]], k: int, rng: random.Random) -> list[list[float]]:
    centers = [points[rng.randrange(len(points))].copy()]
    while len(centers) < k:
        d2s = [min(sq_dist(point, center) for center in centers) for point in points]
        total = sum(d2s)
        if total <= 0.0:
            centers.append(points[rng.randrange(len(points))].copy())
            continue
        pick = rng.random() * total
        running = 0.0
        chosen_idx = len(d2s) - 1
        for idx, d2 in enumerate(d2s):
            running += d2
            if running >= pick:
                chosen_idx = idx
                break
        centers.append(points[chosen_idx].copy())
    return centers


def kmeans(points: list[list[float]], k: int, seed_text: str) -> tuple[list[list[float]], list[int]]:
    seed = int(hashlib.sha256(seed_text.encode("utf-8")).hexdigest()[:12], 16) ^ len(points)
    rng = random.Random(seed)
    centers = kmeans_plus_plus(points, k, rng)
    assignments = [0 for _ in points]
    for _ in range(KMEANS_MAX_ITER):
        changed = False
        for idx, point in enumerate(points):
            best_id = 0
            best_d2 = sq_dist(point, centers[0])
            for cid in range(1, len(centers)):
                d2 = sq_dist(point, centers[cid])
                if d2 < best_d2:
                    best_d2 = d2
                    best_id = cid
            if assignments[idx] != best_id:
                assignments[idx] = best_id
                changed = True
        sums = [[0.0, 0.0, 0] for _ in centers]
        for point, cid in zip(points, assignments):
            sums[cid][0] += point[0]
            sums[cid][1] += point[1]
            sums[cid][2] += 1
        moved = 0.0
        for cid, center in enumerate(centers):
            count = sums[cid][2]
            if count <= 0:
                centers[cid] = points[rng.randrange(len(points))].copy()
                moved += 1.0
                continue
            nx = sums[cid][0] / count
            ny = sums[cid][1] / count
            moved += sq_dist(center, [nx, ny])
            centers[cid] = [nx, ny]
        if not changed or moved <= KMEANS_EPSILON:
            break
    return centers, assignments


def merge_small_clusters(points: list[list[float]], centers: list[list[float]], assignments: list[int]) -> tuple[list[list[float]], list[int]]:
    while True:
        members = build_members_from_assignments(assignments)
        small = {cid: idxs for cid, idxs in members.items() if len(idxs) < MIN_CLUSTER_SIZE}
        if not small or len(centers) <= 1:
            break
        changed = False
        for cid, idxs in small.items():
            if not idxs or len(centers) <= 1:
                continue
            target = None
            best = math.inf
            for other_cid, center in enumerate(centers):
                if other_cid == cid:
                    continue
                d2 = sq_dist(centers[cid], center)
                if d2 < best:
                    best = d2
                    target = other_cid
            if target is None:
                continue
            for idx in idxs:
                assignments[idx] = target
            changed = True
        if not changed:
            break
        used_ids = sorted(set(assignments))
        remap = {old_id: new_id for new_id, old_id in enumerate(used_ids)}
        assignments = [remap[old] for old in assignments]
        centers = [centers[old_id] for old_id in used_ids]
    return centers, assignments


def compute_cluster_stats(points: list[list[float]], members: dict[int, list[int]]) -> dict[int, dict[str, float | int]]:
    stats = {}
    for cid, idxs in members.items():
        cx = sum(points[idx][0] for idx in idxs) / len(idxs)
        cy = sum(points[idx][1] for idx in idxs) / len(idxs)
        dx = math.sqrt(sum((points[idx][0] - cx) ** 2 for idx in idxs) / len(idxs))
        dy = math.sqrt(sum((points[idx][1] - cy) ** 2 for idx in idxs) / len(idxs))
        stats[cid] = {"cx": cx, "cy": cy, "dx": dx, "dy": dy, "count": len(idxs)}
    return stats


def cluster_neighbor_samples(members: dict[int, list[int]], members_sorted: list[int], layout_edges: list[dict[str, Any]], assignments: list[int], notes: list[dict[str, Any]]) -> dict[int, list[dict[str, Any]]]:
    cluster_index = {cid: idx + 1 for idx, cid in enumerate(members_sorted)}
    snippets_by_cluster = {
        cid: [label_excerpt(notes[idx]["text"]) for idx in members[cid][:MAX_LABEL_SNIPPETS] if label_excerpt(notes[idx]["text"])]
        for cid in members_sorted
    }
    scores: dict[tuple[int, int], float] = defaultdict(float)
    for edge in layout_edges:
        ca = assignments[int(edge["source"])]
        cb = assignments[int(edge["target"])]
        if ca == cb:
            continue
        left, right = (ca, cb) if ca < cb else (cb, ca)
        scores[(left, right)] += float(edge["weight"])
    out: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for (ca, cb), weight in scores.items():
        out[ca].append({"cluster_id": cb, "cluster_index": cluster_index[cb], "weight": weight})
        out[cb].append({"cluster_id": ca, "cluster_index": cluster_index[ca], "weight": weight})
    for cid, neighbors in list(out.items()):
        out[cid] = [
            {"cluster_index": neighbor["cluster_index"], "keywords": keywords_from_snippets(snippets_by_cluster.get(neighbor["cluster_id"], []), 6)}
            for neighbor in sorted(neighbors, key=lambda item: (-item["weight"], item["cluster_index"]))[:4]
        ]
    return dict(out)


def cluster_samples_for_labels(
    notes: list[dict[str, Any]],
    points: list[list[float]],
    members: dict[int, list[int]],
    stats: dict[int, dict[str, Any]],
    *,
    degree_scores: dict[int, float] | None = None,
    ordered_cluster_ids: list[int] | None = None,
    neighbor_samples: dict[int, list[dict[str, Any]]] | None = None,
) -> list[dict[str, Any]]:
    cluster_ids = ordered_cluster_ids or sorted(members)
    samples = []
    for order_idx, cid in enumerate(cluster_ids):
        idxs = members[cid]
        center = stats[cid]
        if degree_scores:
            ordered = sorted(idxs, key=lambda idx: (-float(degree_scores.get(idx, 0.0)), idx))
        else:
            ordered = sorted(idxs, key=lambda idx: ((points[idx][0] - center["cx"]) ** 2) + ((points[idx][1] - center["cy"]) ** 2))
        sample_idxs = ordered[: min(len(ordered), MAX_LABEL_SNIPPETS)]
        snippets = [label_excerpt(notes[idx]["text"]) for idx in sample_idxs]
        snippets = [snippet for snippet in snippets if snippet]
        samples.append({
            "cluster_id": cid,
            "cluster_index": order_idx + 1,
            "snippets": snippets,
            "keywords": keywords_from_snippets(snippets, 8),
            "neighbors": (neighbor_samples or {}).get(cid, []),
        })
    return samples


def build_map_payload(
    notes: list[dict[str, Any]],
    points: list[list[float]],
    assignments: list[int],
    members: dict[int, list[int]],
    final_stats: dict[int, dict[str, Any]],
    vector_dim: int,
    labeler: Labeler | None,
    *,
    layout_meta: dict[str, Any] | None = None,
    degree_scores: dict[int, float] | None = None,
    graph_debug: dict[int, dict[str, Any]] | None = None,
    raw_points: list[list[float]] | None = None,
    layout_edges: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    members_sorted = sorted(members, key=lambda cid: (-len(members[cid]), cid))
    neighbor_samples = cluster_neighbor_samples(members, members_sorted, layout_edges or [], assignments, notes)
    cluster_samples = cluster_samples_for_labels(
        notes,
        points,
        members,
        final_stats,
        degree_scores=degree_scores,
        ordered_cluster_ids=members_sorted,
        neighbor_samples=neighbor_samples,
    )
    cluster_sample_by_id = {sample["cluster_id"]: sample for sample in cluster_samples}
    llm_labels = labeler.generate_cluster_labels(cluster_samples) if labeler else {}
    cluster_id_order_map: dict[int, str] = {}
    final_label_keys: set[str] = set()
    clusters = []
    for order_idx, cid in enumerate(members_sorted):
        stat = final_stats[cid]
        cluster_index = order_idx + 1
        cluster_id = f"mountain-{cluster_index}"
        cluster_id_order_map[cid] = cluster_id
        sample = cluster_sample_by_id.get(cid, {"snippets": [], "keywords": []})
        label_details = llm_labels.get(cluster_index, {})
        label = str(label_details.get("primaryLabel") or "")
        if not label:
            label = fallback_label(sample["snippets"], cluster_index, final_label_keys)
            label_details = {"primaryLabel": label, "subtitle": "", "keywordChips": sample["keywords"][:3]}
        key = label_key(label)
        if key in final_label_keys:
            label = fallback_label(sample["snippets"], cluster_index, final_label_keys)
            label_details = {**label_details, "primaryLabel": label}
            key = label_key(label)
        final_label_keys.add(key)
        clusters.append({
            "id": cluster_id,
            "label": label,
            "primaryLabel": label,
            "subtitle": str(label_details.get("subtitle") or ""),
            "keywordChips": list(label_details.get("keywordChips") or [])[:3],
            "centerX": round(float(stat["cx"]), 2),
            "centerY": round(float(stat["cy"]), 2),
            "spreadX": round(float(stat["dx"]) + 36.0, 2),
            "spreadY": round(float(stat["dy"]) + 36.0, 2),
            "noteCount": int(stat["count"]),
        })

    notes_payload = []
    for idx, note in enumerate(notes):
        cid = assignments[idx]
        debug = (graph_debug or {}).get(idx, {})
        notes_payload.append({
            "id": f"{note['lookup']}::{note['path']}#{note['chunk']}",
            "index": idx,
            "lookup": note["lookup"],
            "path": note["path"],
            "chunk": note["chunk"],
            "hash": note["hash"],
            "title": note["id"],
            "url": note["url"],
            "snippet": map_snippet(note["text"]),
            "x": round(points[idx][0], 2),
            "y": round(points[idx][1], 2),
            "rawX": round(raw_points[idx][0], 4) if raw_points else None,
            "rawY": round(raw_points[idx][1], 4) if raw_points else None,
            "clusterId": cluster_id_order_map[cid],
            "communityId": debug.get("community_id", cid),
            "degree": debug.get("degree", 0),
            "internalWeight": round(float(debug.get("internal_weight", 0.0)), 4),
            "externalWeight": round(float(debug.get("external_weight", 0.0)), 4),
            "bridgeScore": round(float(debug.get("bridge_score", 0.0)), 4),
        })

    edges_payload = [
        {
            "sourceIndex": int(edge["source"]),
            "targetIndex": int(edge["target"]),
            "weight": round(float(edge["weight"]), 4),
            "sameCommunity": bool(edge.get("same_community")),
            "bridge": bool(edge.get("bridge")),
            "mutual": bool(edge.get("mutual")),
        }
        for edge in (layout_edges or [])
    ]
    payload = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "noteCount": len(notes_payload),
        "vectorDim": vector_dim,
        "width": MAP_WIDTH,
        "height": MAP_HEIGHT,
        "clusters": clusters,
        "notes": notes_payload,
        "edges": edges_payload,
    }
    if layout_meta:
        payload["layout"] = layout_meta
    return payload


def build_map_data_with_kmeans(notes: list[dict[str, Any]], vector_dim: int, labeler: Labeler | None, fallback_reason: str | None = None) -> dict[str, Any]:
    embeddings = [note["embedding"] for note in notes]
    a_idx, b_idx, c_idx = choose_anchor_indices(embeddings)
    a = embeddings[a_idx]
    b = embeddings[b_idx]
    c = embeddings[c_idx]
    raw_x = [dot(e, a) - dot(e, b) for e in embeddings]
    raw_y = [dot(e, c) - 0.5 * (dot(e, a) + dot(e, b)) for e in embeddings]
    px = normalize_to_canvas(raw_x, MAP_MARGIN, MAP_WIDTH - MAP_MARGIN)
    py = normalize_to_canvas(raw_y, MAP_MARGIN, MAP_HEIGHT - MAP_MARGIN)
    points = [[x, py[idx]] for idx, x in enumerate(px)]
    k = desired_cluster_count(len(notes))
    centers, assignments = kmeans(points, k, f"map-kmeans:{len(notes)}:{vector_dim}")
    _centers, assignments = merge_small_clusters(points, centers, assignments)
    members = build_members_from_assignments(assignments)
    final_stats = compute_cluster_stats(points, members)
    layout_meta = {
        "method": "kmeans",
        "layoutMethod": "global_embedding_projection",
        "communityUsage": "ids_labels_metadata_only",
    }
    if fallback_reason:
        layout_meta["fallbackReason"] = fallback_reason
    return build_map_payload(notes, points, assignments, members, final_stats, vector_dim, labeler, layout_meta=layout_meta)


def build_map_data_with_graph(config: Config, notes: list[dict[str, Any]], vector_dim: int, labeler: Labeler | None) -> dict[str, Any]:
    k = graph_knn_k(config, len(notes))
    min_size = graph_community_min_size(config)
    min_edge_weight = graph_edge_min_weight(config)
    iterations = map_layout_iterations(config)
    directed_edges = build_knn_edges(notes, k)
    graph = symmetrize_knn_edges(directed_edges, len(notes), min_edge_weight)
    adjacency = graph["adjacency"]
    edges = graph["edges"]
    print(f"Undirected edges: {len(edges)}")
    if not edges:
        raise ValueError("kNN graph has no usable edges; lower map.graphEdgeMinWeight or check vector search results")
    assignments = detect_communities_weighted_local_moving(adjacency, min_size)
    for idx, cid in enumerate(assignments):
        notes[idx]["community_id"] = cid
    members = build_members_from_assignments(assignments)
    if len(members) > MAP_MAX_GRAPH_COMMUNITIES:
        raise ValueError(f"Graph community count too high ({len(members)}); check kNN graph connectivity or increase map.communityMinSize")
    print(f"Detected communities: {len(members)}")
    layout_edges = retain_layout_edges(edges, assignments, MAP_CROSS_COMMUNITY_EDGES_PER_NODE)
    layout_graph = graph_from_edges(layout_edges, len(notes))
    layout_adjacency = layout_graph["adjacency"]
    bridge_count = sum(1 for edge in layout_edges if edge.get("bridge"))
    print(f"Retained layout edges: {len(layout_edges)} (bridges={bridge_count})")
    print(f"Running force layout: iterations={iterations}")
    layout_result = layout_graph_force(layout_adjacency, assignments, iterations=iterations, width=MAP_WIDTH, height=MAP_HEIGHT, margin=MAP_MARGIN)
    force_points = layout_result["points"]
    print("Shaping layout into mountain regions")
    mountain_result = shape_points_as_mountains(
        force_points,
        layout_adjacency,
        assignments,
        width=MAP_WIDTH,
        height=MAP_HEIGHT,
        margin=MAP_MARGIN,
    )
    points = mountain_result["points"]
    raw_points = force_points
    final_stats = compute_cluster_stats(points, members)
    graph_debug = node_graph_debug(layout_adjacency, assignments)
    degree_scores = {idx: float(debug["internal_weight"]) for idx, debug in graph_debug.items()}
    layout_meta = {
        "method": "graph",
        "knnK": k,
        "retainedCrossCommunityEdgesPerNode": MAP_CROSS_COMMUNITY_EDGES_PER_NODE,
        "communityMethod": "weighted_local_moving",
        "communityUsage": "ids_labels_metadata_only",
        "layoutMethod": "global_force_directed_mountain_shaped",
        "edgeCount": len(edges),
        "retainedEdgeCount": len(layout_edges),
        "bridgeEdgeCount": bridge_count,
        "sameCommunityIdealLength": SAME_COMMUNITY_EDGE_IDEAL,
        "crossCommunityIdealLength": CROSS_COMMUNITY_EDGE_IDEAL,
        "sameCommunityAttraction": SAME_COMMUNITY_ATTRACTION,
        "crossCommunityAttraction": CROSS_COMMUNITY_ATTRACTION,
        "communityGravity": COMMUNITY_GRAVITY,
    }
    return build_map_payload(
        notes,
        points,
        assignments,
        members,
        final_stats,
        vector_dim,
        labeler,
        layout_meta=layout_meta,
        degree_scores=degree_scores,
        graph_debug=graph_debug,
        raw_points=raw_points,
        layout_edges=layout_edges,
    )


def build_map_data(config: Config, notes: list[dict[str, Any]], labeler: Labeler | None) -> dict[str, Any]:
    vector_dim = prepare_notes_for_map(notes)
    requested_layout = map_layout_requested(config) or MAP_LAYOUT_DEFAULT
    print(f"Map layout requested: {requested_layout}")
    print("sqlite-vec available: false")
    if graph_layout_enabled(config):
        print("Map layout: graph")
        return build_map_data_with_graph(config, notes, vector_dim, labeler)
    print("Map layout: kmeans")
    return build_map_data_with_kmeans(notes, vector_dim, labeler)
