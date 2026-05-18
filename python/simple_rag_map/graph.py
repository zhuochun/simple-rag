from __future__ import annotations

from collections import defaultdict
import math
from typing import Any


MAP_CROSS_COMMUNITY_EDGES_PER_NODE = 4
SAME_COMMUNITY_EDGE_IDEAL = 34.0
CROSS_COMMUNITY_EDGE_IDEAL = 76.0
SAME_COMMUNITY_ATTRACTION = 0.018
CROSS_COMMUNITY_ATTRACTION = 0.012
COMMUNITY_GRAVITY = 0.0014
NODE_INITIAL_TEMP = 18.0


def dot(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b))


def safe_normalize(vec: list[float]) -> list[float] | None:
    norm = math.sqrt(sum(value * value for value in vec))
    if norm <= 0.0:
        return None
    return [value / norm for value in vec]


def build_knn_edges(notes: list[dict[str, Any]], k: int) -> list[tuple[int, int, float]]:
    try:
        import numpy as np  # type: ignore
    except ImportError:
        return build_knn_edges_pure(notes, k)

    print(f"Building kNN graph with numpy: notes={len(notes)}, k={k}")
    embeddings = np.asarray([note["embedding"] for note in notes], dtype=np.float32)
    node_count = embeddings.shape[0]
    directed: list[tuple[int, int, float]] = []
    batch_size = 512
    for start in range(0, node_count, batch_size):
        stop = min(start + batch_size, node_count)
        scores = embeddings[start:stop] @ embeddings.T
        for row_idx, src_idx in enumerate(range(start, stop)):
            scores[row_idx, src_idx] = -1.0
        take = min(k, max(node_count - 1, 0))
        if take <= 0:
            continue
        top = np.argpartition(-scores, take - 1, axis=1)[:, :take]
        for row_idx, src_idx in enumerate(range(start, stop)):
            ordered = sorted(((int(dst), float(scores[row_idx, dst])) for dst in top[row_idx]), key=lambda item: (-item[1], item[0]))
            for dst_idx, weight in ordered:
                directed.append((src_idx, dst_idx, min(max(weight, 0.0), 1.0)))
    print(f"Built directed kNN edges: {len(directed)}")
    return directed


def build_knn_edges_pure(notes: list[dict[str, Any]], k: int) -> list[tuple[int, int, float]]:
    print(f"Building kNN graph with pure Python: notes={len(notes)}, k={k}")
    embeddings = [note["embedding"] for note in notes]
    directed: list[tuple[int, int, float]] = []
    for src_idx, src in enumerate(embeddings):
        neighbors = []
        for dst_idx, dst in enumerate(embeddings):
            if src_idx == dst_idx:
                continue
            weight = min(max(dot(src, dst), 0.0), 1.0)
            neighbors.append((dst_idx, weight))
        for dst_idx, weight in sorted(neighbors, key=lambda item: (-item[1], item[0]))[:k]:
            directed.append((src_idx, dst_idx, weight))
    print(f"Built directed kNN edges: {len(directed)}")
    return directed


def symmetrize_knn_edges(
    directed_edges: list[tuple[int, int, float]],
    node_count: int,
    min_weight: float,
) -> dict[str, Any]:
    pair_weights: dict[tuple[int, int], dict[tuple[int, int], float]] = {}
    for src, dst, weight in directed_edges:
        if src == dst:
            continue
        a, b = (src, dst) if src < dst else (dst, src)
        pair_weights.setdefault((a, b), {})[(src, dst)] = float(weight)

    adjacency: list[dict[int, float]] = [dict() for _ in range(node_count)]
    edges: list[dict[str, Any]] = []
    for (a, b), directed in pair_weights.items():
        wab = directed.get((a, b))
        wba = directed.get((b, a))
        mutual = wab is not None and wba is not None
        weight = max(wab, wba) * 1.15 if wab is not None and wba is not None else float(wab if wab is not None else wba)
        weight = min(max(weight, 0.0), 1.0)
        if weight < min_weight:
            continue
        adjacency[a][b] = weight
        adjacency[b][a] = weight
        edges.append({"source": a, "target": b, "weight": weight, "mutual": mutual})
    return {"node_count": node_count, "adjacency": adjacency, "edges": edges}


def graph_from_edges(edges: list[dict[str, Any]], node_count: int) -> dict[str, Any]:
    adjacency: list[dict[int, float]] = [dict() for _ in range(node_count)]
    for edge in edges:
        a = int(edge["source"])
        b = int(edge["target"])
        weight = float(edge["weight"])
        adjacency[a][b] = weight
        adjacency[b][a] = weight
    return {"node_count": node_count, "adjacency": adjacency, "edges": edges}


def retain_layout_edges(edges: list[dict[str, Any]], communities: list[int], cross_per_node: int) -> list[dict[str, Any]]:
    retained: dict[tuple[int, int], dict[str, Any]] = {}
    cross_by_node: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for edge in edges:
        a = int(edge["source"])
        b = int(edge["target"])
        same = communities[a] == communities[b]
        key = (a, b) if a < b else (b, a)
        if same or edge.get("mutual"):
            retained[key] = {**edge, "same_community": same, "bridge": not same}
        if same:
            continue
        cross_by_node[a].append(edge)
        cross_by_node[b].append(edge)

    for node_edges in cross_by_node.values():
        for edge in sorted(node_edges, key=lambda item: (-float(item["weight"]), int(item["source"]), int(item["target"])))[:cross_per_node]:
            a = int(edge["source"])
            b = int(edge["target"])
            key = (a, b) if a < b else (b, a)
            retained[key] = {**edge, "same_community": False, "bridge": True}
    return sorted(retained.values(), key=lambda item: (int(item["source"]), int(item["target"])))


def build_members_from_assignments(assignments: list[int]) -> dict[int, list[int]]:
    members: dict[int, list[int]] = defaultdict(list)
    for idx, cid in enumerate(assignments):
        members[cid].append(idx)
    return dict(members)


def merge_small_communities(assignments: list[int], adjacency: list[dict[int, float]], min_size: int) -> list[int]:
    while True:
        members = build_members_from_assignments(assignments)
        small = {cid: idxs for cid, idxs in members.items() if len(idxs) < min_size}
        if not small:
            break
        changed = False
        for cid in sorted(small):
            score_by_community: dict[int, float] = defaultdict(float)
            for idx in small[cid]:
                for neighbor_idx, weight in adjacency[idx].items():
                    neighbor_cid = assignments[neighbor_idx]
                    if neighbor_cid != cid:
                        score_by_community[neighbor_cid] += float(weight)
            if not score_by_community:
                continue
            target_cid = sorted(score_by_community.items(), key=lambda item: (-item[1], item[0]))[0][0]
            for idx in small[cid]:
                assignments[idx] = target_cid
            changed = True
        if not changed:
            break

    members = build_members_from_assignments(assignments)
    ordered = sorted(members, key=lambda cid: (-len(members[cid]), cid))
    remap = {cid: dense for dense, cid in enumerate(ordered)}
    return [remap[cid] for cid in assignments]


def detect_communities_weighted_local_moving(adjacency: list[dict[int, float]], min_size: int) -> list[int]:
    node_count = len(adjacency)
    assignments = list(range(node_count))
    epsilon = 1e-9
    for _ in range(30):
        moved = False
        community_sizes: dict[int, int] = defaultdict(int)
        for cid in assignments:
            community_sizes[cid] += 1
        for idx in range(node_count):
            current = assignments[idx]
            neighbor_scores: dict[int, float] = defaultdict(float)
            for neighbor_idx, weight in adjacency[idx].items():
                neighbor_scores[assignments[neighbor_idx]] += float(weight)
            if not neighbor_scores:
                continue
            current_score = neighbor_scores[current] / math.sqrt(max(community_sizes[current], 1))
            best_cid = current
            best_score = current_score
            for candidate_cid in sorted(neighbor_scores):
                score = neighbor_scores[candidate_cid] / math.sqrt(max(community_sizes[candidate_cid], 1))
                if score > best_score + epsilon:
                    best_score = score
                    best_cid = candidate_cid
            if best_cid == current:
                continue
            assignments[idx] = best_cid
            community_sizes[current] -= 1
            community_sizes[best_cid] += 1
            moved = True
        if not moved:
            break
    return merge_small_communities(assignments, adjacency, min_size)


def normalize_points_to_canvas(points: list[list[float]], width: int, height: int, margin: int) -> None:
    if not points:
        return
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    min_x, max_x = min(xs), max(xs)
    min_y, max_y = min(ys), max(ys)
    span_x = max_x - min_x
    span_y = max_y - min_y
    available_w = width - (2.0 * margin)
    available_h = height - (2.0 * margin)
    if abs(span_x) < 1e-9 and abs(span_y) < 1e-9:
        cx = width / 2.0
        cy = height / 2.0
        for idx, point in enumerate(points):
            angle = idx * math.pi * (3.0 - math.sqrt(5.0))
            radius = 2.0 + (idx % 11)
            point[0] = cx + math.cos(angle) * radius
            point[1] = cy + math.sin(angle) * radius
        return

    scale_x = math.inf if abs(span_x) < 1e-9 else available_w / span_x
    scale_y = math.inf if abs(span_y) < 1e-9 else available_h / span_y
    scale = min(scale_x, scale_y)
    if not math.isfinite(scale) or scale <= 0.0:
        scale = 1.0
    out_w = span_x * scale
    out_h = span_y * scale
    offset_x = margin + ((available_w - out_w) / 2.0)
    offset_y = margin + ((available_h - out_h) / 2.0)
    for point in points:
        point[0] = min(max(offset_x + ((point[0] - min_x) * scale), margin), width - margin)
        point[1] = min(max(offset_y + ((point[1] - min_y) * scale), margin), height - margin)


def layout_graph_force(
    adjacency: list[dict[int, float]],
    communities: list[int],
    *,
    iterations: int,
    width: int,
    height: int,
    margin: int,
) -> dict[str, list[list[float]]]:
    node_count = len(adjacency)
    members = build_members_from_assignments(communities)
    center_x = width / 2.0
    center_y = height / 2.0
    points = []
    for idx in range(node_count):
        angle = idx * math.pi * (3.0 - math.sqrt(5.0))
        radius = 7.0 * math.sqrt(idx + 1)
        points.append([center_x + math.cos(angle) * radius, center_y + math.sin(angle) * radius])

    edges = []
    for i, neighbors in enumerate(adjacency):
        for j, weight in neighbors.items():
            if j > i:
                edges.append((i, j, float(weight)))

    for iteration in range(iterations):
        forces = [[0.0, 0.0] for _ in range(node_count)]
        for a, b, weight in edges:
            dx = points[b][0] - points[a][0]
            dy = points[b][1] - points[a][1]
            dist = max(math.sqrt((dx * dx) + (dy * dy)), 1.0)
            ux = dx / dist
            uy = dy / dist
            same = communities[a] == communities[b]
            ideal = SAME_COMMUNITY_EDGE_IDEAL if same else CROSS_COMMUNITY_EDGE_IDEAL
            strength = SAME_COMMUNITY_ATTRACTION if same else CROSS_COMMUNITY_ATTRACTION
            force = strength * weight * (dist - ideal)
            fx = ux * force
            fy = uy * force
            forces[a][0] += fx
            forces[a][1] += fy
            forces[b][0] -= fx
            forces[b][1] -= fy

        if node_count <= 1200:
            pairs = ((a, b) for a in range(node_count) for b in range(a + 1, node_count))
        else:
            offsets = (1, 7, 19, 43, 97, 211)
            pairs = ((a, a + offset) for a in range(node_count) for offset in offsets if a + offset < node_count)
        for a, b in pairs:
            dx = points[b][0] - points[a][0]
            dy = points[b][1] - points[a][1]
            dist2 = max((dx * dx) + (dy * dy), 16.0)
            dist = math.sqrt(dist2)
            ux = dx / dist
            uy = dy / dist
            rep = 18.0 / dist2
            fx = ux * rep
            fy = uy * rep
            forces[a][0] -= fx
            forces[a][1] -= fy
            forces[b][0] += fx
            forces[b][1] += fy

        centroids: dict[int, tuple[float, float]] = {}
        for cid, idxs in members.items():
            sx = sum(points[idx][0] for idx in idxs)
            sy = sum(points[idx][1] for idx in idxs)
            centroids[cid] = (sx / len(idxs), sy / len(idxs))
        for idx in range(node_count):
            centroid = centroids.get(communities[idx])
            if centroid is None:
                continue
            forces[idx][0] += (centroid[0] - points[idx][0]) * COMMUNITY_GRAVITY
            forces[idx][1] += (centroid[1] - points[idx][1]) * COMMUNITY_GRAVITY

        temperature = NODE_INITIAL_TEMP * (1.0 - (iteration / iterations))
        max_step = max(temperature, 1.0)
        for idx in range(node_count):
            fx, fy = forces[idx]
            step = math.sqrt((fx * fx) + (fy * fy))
            if step > max_step:
                scale = max_step / step
                fx *= scale
                fy *= scale
            points[idx][0] += fx
            points[idx][1] += fy

    raw_points = [point.copy() for point in points]
    normalize_points_to_canvas(points, width, height, margin)
    return {"points": points, "raw_points": raw_points}


def node_graph_debug(adjacency: list[dict[int, float]], communities: list[int]) -> dict[int, dict[str, float | int]]:
    debug: dict[int, dict[str, float | int]] = {}
    for idx, neighbors in enumerate(adjacency):
        internal = 0.0
        external = 0.0
        for neighbor_idx, weight in neighbors.items():
            if communities[idx] == communities[neighbor_idx]:
                internal += float(weight)
            else:
                external += float(weight)
        total = internal + external
        debug[idx] = {
            "community_id": communities[idx],
            "degree": len(neighbors),
            "internal_weight": internal,
            "external_weight": external,
            "bridge_score": 0.0 if total <= 0.0 else external / total,
        }
    return debug
