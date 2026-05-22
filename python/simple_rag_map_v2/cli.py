from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys
import tempfile

from .communities import detect_communities
from .config import load_config, selected_paths
from .debug import build_debug
from .graph import build_knn_graph, node_edge_metrics
from .io import load_indexed_notes
from .labels import assign_labels, build_anchor_profiles, build_cluster_profiles, label_cache_path
from .layout import community_centers, mountain_layout, reframe_layout, semantic_layout
from .schema import build_payload, json_dumps
from .terrain import build_terrain, cluster_peak_anchors
from .vectors import validate_and_normalize
from simple_rag_map.llm import ensure_ollama_started, missing_key_message, should_start_ollama


STAGES = ("all", "graph", "communities", "layout", "terrain", "labels")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        config = load_config(args.config, seed=args.seed, label_workers=args.label_workers)
        if config.map_v2.labels.enabled and args.stage in {"all", "labels"}:
            missing = missing_key_message(config, ("chat",))
            if missing:
                print(missing)
                return 9
            if should_start_ollama(config, ("chat",)) and not ensure_ollama_started(config, ("chat",)):
                return 9
        paths = selected_paths(config, args.include_paths)
        print(f"Selected paths: {', '.join(path.name for path in paths)}")
        result = run_pipeline(config, paths, stage=args.stage, debug=args.debug)
        write_json(config.map_v2.output_path, result["map_data"])
        print(f"Map data generated: {config.map_v2.output_path} (stage={args.stage})")
        if args.debug:
            debug_path = config.map_v2.output_path.with_name("map_debug.json")
            write_json(debug_path, result["debug"])
            print(f"Debug data generated: {debug_path}")
        print(
            f"Notes: {result['map_data']['noteCount']}, mountains: {len(result['map_data']['clusters'])}, "
            f"vector_dim: {result['map_data']['vectorDim']}"
        )
        return 0
    except Exception as exc:
        print(f"run-index-map-v2 failed: {exc.__class__.__name__}: {exc}")
        return 1


def run_pipeline(config, paths, *, stage: str, debug: bool):
    notes = load_indexed_notes(paths)
    embeddings, vector_dim, embedding_stats = validate_and_normalize(notes)
    graph = build_knn_graph(embeddings, config.map_v2.knn_k)
    communities = detect_communities(
        len(notes),
        graph["edges"],
        resolution=config.map_v2.community_resolution,
        min_size=config.map_v2.min_community_size,
        seed=config.map_v2.random_state,
    )
    assignments = communities["assignments"]
    semantic = semantic_layout(embeddings, config.map_v2.semantic_layout)
    node_metrics = node_edge_metrics(len(notes), graph["edges"], assignments)
    centers = community_centers(assignments, graph["edges"], config.map_v2.random_state, config.map_v2.cartography.mountain_separation)
    mountain = mountain_layout(
        semantic["normalized"],
        assignments,
        graph["edges"],
        node_metrics,
        centers,
        config.map_v2.cartography,
        config.map_v2.random_state,
    )
    framed = reframe_layout(mountain["points"], centers)
    points = framed["points"]
    centers = framed["centers"]
    terrain = build_terrain(points, mountain["densityWeight"], config.map_v2.terrain, width=framed["width"], height=framed["height"]) if stage in {"all", "terrain", "labels"} else None
    peak_anchors = cluster_peak_anchors(points, assignments, mountain["densityWeight"], config.map_v2.terrain)
    profiles = build_cluster_profiles(notes, assignments, node_metrics, graph["edges"])
    anchor_profiles = build_anchor_profiles(notes, assignments, node_metrics, peak_anchors, points)
    cache_path = label_cache_path(config.map_v2.output_path, config.map_v2.labels.label_cache_path)
    labels = assign_labels(config, profiles, cache_path, max_workers=config.map_v2.labels.label_workers) if config.map_v2.labels.enabled and stage in {"all", "labels"} else {}
    anchor_labels = {}
    if config.map_v2.labels.enabled and stage in {"all", "labels"}:
        raw_anchor_labels = assign_labels(config, anchor_profiles, cache_path, max_workers=config.map_v2.labels.label_workers)
        anchor_labels = {
            profile["anchorKey"]: raw_anchor_labels[idx]
            for idx, profile in enumerate(anchor_profiles, start=1)
            if idx in raw_anchor_labels
        }
    layout_meta = {
        "method": "semantic_cartography_v2",
        "semanticMethod": semantic["method"],
        "communityMethod": communities["method"],
        "knnK": config.map_v2.knn_k,
        "communityResolution": config.map_v2.community_resolution,
        "minCommunitySize": config.map_v2.min_community_size,
        "randomState": config.map_v2.random_state,
        "stage": stage,
        "semanticCoordinates": "semanticX/semanticY",
        "displayCoordinates": "x/y",
        "mapExtent": {"width": framed["width"], "height": framed["height"], **framed["bounds"]},
    }
    if semantic.get("fallbackReason"):
        layout_meta["semanticFallbackReason"] = semantic["fallbackReason"]
    payload = build_payload(
        notes,
        vector_dim,
        assignments,
        semantic["normalized"],
        points,
        node_metrics,
        mountain["densityWeight"],
        graph["edges"],
        centers,
        profiles,
        labels,
        terrain,
        layout_meta,
        framed["width"],
        framed["height"],
        peak_anchors,
        anchor_labels,
    )
    debug_payload = build_debug(
        embedding_stats,
        graph["stats"],
        communities["stats"],
        {
            "method": semantic["method"],
            "params": {
                "nNeighbors": config.map_v2.semantic_layout.n_neighbors,
                "minDist": config.map_v2.semantic_layout.min_dist,
                "metric": config.map_v2.semantic_layout.metric,
                "randomState": config.map_v2.semantic_layout.random_state,
            },
            "rawBounds": _bounds(semantic["raw"]),
            "fallbackReason": semantic.get("fallbackReason"),
        },
        centers,
        terrain,
        profiles,
        node_metrics,
        {
            "mountainSeparation": config.map_v2.cartography.mountain_separation,
            "mountainShapeStrength": config.map_v2.cartography.mountain_shape_strength,
            "bridgeBlend": config.map_v2.cartography.bridge_blend,
            "corePacking": config.map_v2.cartography.core_packing,
            "foothillSpread": config.map_v2.cartography.foothill_spread,
        },
    )
    return {"map_data": payload, "debug": debug_payload}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="run-index-map-v2", description="Build semantic mountain map_data.json from simple-rag indexes.")
    parser.add_argument("config", help="Path to config.json")
    parser.add_argument("include_paths", nargs="?", help='Optional path names: learning,kaizen or ["learning","kaizen"]')
    parser.add_argument("--stage", choices=STAGES, default="all")
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--label-workers", type=int, default=None)
    return parser.parse_args(argv)


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", suffix=".tmp", delete=False) as temp:
            temp_name = temp.name
            temp.write(json_dumps(data))
            temp.flush()
            os.fsync(temp.fileno())
        os.replace(temp_name, path)
        temp_name = None
    finally:
        if temp_name:
            try:
                Path(temp_name).unlink()
            except OSError:
                pass


def _bounds(points) -> dict[str, float]:
    return {
        "minX": float(points[:, 0].min()),
        "maxX": float(points[:, 0].max()),
        "minY": float(points[:, 1].min()),
        "maxY": float(points[:, 1].max()),
    }


if __name__ == "__main__":
    raise SystemExit(main())
