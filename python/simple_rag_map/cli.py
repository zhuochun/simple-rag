from __future__ import annotations

import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import sys
import tempfile
from typing import Any

from .config import Config, load_config, map_value
from .labels import MAX_LABEL_SNIPPETS, Labeler, keywords_from_snippets, label_excerpt
from .llm import ensure_ollama_started, missing_key_message, should_start_ollama
from .pipeline import build_map_data, load_all_notes


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)

    config_file = Path(args.config).resolve()
    config_base_dir = config_file.parent

    try:
        config = load_config(config_file)
    except Exception as exc:
        print(f"Config error: {exc}")
        return 1

    try:
        map_out_file = map_out_file_required(config, config_base_dir)
        provider_sections = provider_sections_for_step(args.step)
        missing = missing_key_message(config, provider_sections)
        if missing:
            print(missing)
            return 9
        if provider_sections and should_start_ollama(config, provider_sections) and not ensure_ollama_started(config, provider_sections):
            return 9
        labeler = Labeler(config, label_cache_path(config, map_out_file), max_workers=label_workers(config, args.label_workers))

        if args.step in ("clusters", "all"):
            target_paths = resolve_target_paths(config, args.include_paths)
            print(f"Selected paths: {', '.join(path.name for path in target_paths)}")
            notes = load_all_notes(target_paths)
            map_data = build_map_data(config, notes, None)
            if args.step == "all":
                write_map_data(map_out_file, map_data)
                print(f"Cluster-stage map data generated: {map_out_file}")
                apply_labels_to_map_data(map_data, labeler)
        else:
            map_data = load_existing_map_data(map_out_file)
            apply_labels_to_map_data(map_data, labeler)

        write_map_data(map_out_file, map_data)
        print(f"Map data generated: {map_out_file} (step={args.step})")
        print(f"Notes: {map_data['noteCount']}, mountains: {len(map_data['clusters'])}, vector_dim: {map_data['vectorDim']}")
        return 0
    except Exception as exc:
        print(f"run-index-map failed: {exc.__class__.__name__}: {exc}")
        return 1


def provider_sections_for_step(step: str) -> tuple[str, ...]:
    if step == "clusters":
        return ()
    return ("chat",)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="run-index-map-py",
        description="Build map_data.json clusters and optionally generate LLM labels.",
    )
    parser.add_argument("config", help="Path to config.json")
    parser.add_argument("include_paths", nargs="?", help='Optional path names: learning,kaizen or ["learning","kaizen"]')
    parser.add_argument(
        "--step",
        "--stage",
        choices=("clusters", "labels", "all"),
        default="all",
        help="clusters: build layout with fast fallback labels; labels: relabel existing map JSON; all: do both",
    )
    parser.add_argument(
        "--label-workers",
        type=int,
        default=None,
        help="Concurrent LLM label requests. Defaults to map.labelWorkers or 4.",
    )
    return parser.parse_args(argv)


def parse_include_names(raw: str | None) -> list[str] | None:
    if raw is None or str(raw).strip() == "":
        return None
    txt = str(raw).strip()
    if txt.startswith("["):
        parsed = json.loads(txt)
        if not isinstance(parsed, list):
            raise ValueError("Path filter must be a JSON array when using bracket syntax")
        raw_names = parsed
    else:
        raw_names = txt.split(",")
    names = list(dict.fromkeys(str(name).strip() for name in raw_names if str(name).strip()))
    if not names:
        raise ValueError("Path filter is empty")
    return names


def config_include_names(config: Config) -> list[str] | None:
    raw = map_value(config, "includePaths")
    if raw is None:
        return None
    raw_names = raw if isinstance(raw, list) else [raw]
    names = list(dict.fromkeys(str(name).strip() for name in raw_names if str(name).strip()))
    if not names:
        raise ValueError("map.includePaths is present but empty")
    return names


def resolve_target_paths(config: Config, cli_include_raw: str | None):
    names = parse_include_names(cli_include_raw) or config_include_names(config)
    if names is None:
        return config.paths
    known = [path.name for path in config.paths]
    unknown = [name for name in names if name not in known]
    if unknown:
        raise ValueError(f"Unknown path names in include filter: {', '.join(unknown)}")
    selected = [path for path in config.paths if path.name in names]
    if not selected:
        raise ValueError("No paths selected for map generation")
    return selected


def map_out_file_required(config: Config, config_base_dir: Path) -> Path:
    configured = str(map_value(config, "path", "")).strip()
    if not configured:
        raise ValueError('Config field "map.path" is required for run-index-map')
    path = Path(configured)
    return path if path.is_absolute() else (config_base_dir / path).resolve()


def label_cache_path(config: Config, map_out_file: Path) -> Path | None:
    raw: Any = map_value(config, "labelCachePath")
    if raw is False or str(raw).strip().lower() == "false":
        return None
    configured = str(raw).strip() if raw is not None else ""
    if configured:
        path = Path(configured)
        return path if path.is_absolute() else (map_out_file.parent / path).resolve()
    return map_out_file.with_name(f"{map_out_file.name}.labels.json")


def label_workers(config: Config, cli_value: int | None) -> int:
    raw = cli_value if cli_value is not None else map_value(config, "labelWorkers", 4)
    try:
        return max(1, int(raw))
    except (TypeError, ValueError):
        raise ValueError("Invalid map.labelWorkers: must be an integer >= 1")


def load_existing_map_data(map_out_file: Path) -> dict[str, Any]:
    if not map_out_file.exists():
        raise ValueError(f"Cannot run --step labels because map data does not exist: {map_out_file}")
    with map_out_file.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict) or not isinstance(data.get("clusters"), list) or not isinstance(data.get("notes"), list):
        raise ValueError(f"Invalid map data file: {map_out_file}")
    return data


def write_map_data(map_out_file: Path, map_data: dict[str, Any]) -> None:
    map_out_file.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(map_data, ensure_ascii=False, indent=2) + "\n"
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=map_out_file.parent,
            prefix=f".{map_out_file.name}.",
            suffix=".tmp",
            delete=False,
        ) as temp_file:
            temp_name = temp_file.name
            temp_file.write(payload)
            temp_file.flush()
            os.fsync(temp_file.fileno())
        os.replace(temp_name, map_out_file)
        temp_name = None
    finally:
        if temp_name:
            try:
                Path(temp_name).unlink()
            except OSError:
                pass


def apply_labels_to_map_data(map_data: dict[str, Any], labeler: Labeler) -> None:
    samples = cluster_samples_from_map_data(map_data)
    labels = labeler.generate_cluster_labels(samples)
    for idx, cluster in enumerate(map_data.get("clusters", []), start=1):
        label_details = labels.get(idx)
        if not label_details:
            continue
        primary = str(label_details.get("primaryLabel") or "").strip()
        if not primary:
            continue
        cluster["label"] = primary
        cluster["primaryLabel"] = primary
        cluster["subtitle"] = str(label_details.get("subtitle") or "")
        cluster["keywordChips"] = list(label_details.get("keywordChips") or [])[:3]


def cluster_samples_from_map_data(map_data: dict[str, Any]) -> list[dict[str, Any]]:
    notes_by_cluster: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for note in map_data.get("notes", []):
        cluster_id = note.get("clusterId")
        if cluster_id:
            notes_by_cluster[str(cluster_id)].append(note)

    neighbor_samples = cluster_neighbor_samples_from_map_data(map_data)
    samples = []
    for idx, cluster in enumerate(map_data.get("clusters", []), start=1):
        cluster_id = str(cluster.get("id") or f"mountain-{idx}")
        notes = sorted(
            notes_by_cluster.get(cluster_id, []),
            key=lambda note: (-float(note.get("internalWeight") or 0.0), int(note.get("index") or 0)),
        )
        snippets = [
            label_excerpt(str(note.get("snippet") or ""))
            for note in notes[:MAX_LABEL_SNIPPETS]
        ]
        snippets = [snippet for snippet in snippets if snippet]
        samples.append({
            "cluster_id": cluster_id,
            "cluster_index": idx,
            "snippets": snippets,
            "keywords": keywords_from_snippets(snippets, 8),
            "neighbors": neighbor_samples.get(cluster_id, []),
        })
    return samples


def cluster_neighbor_samples_from_map_data(map_data: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    clusters = list(map_data.get("clusters", []))
    cluster_ids = [str(cluster.get("id") or f"mountain-{idx + 1}") for idx, cluster in enumerate(clusters)]
    cluster_order = {cluster_id: idx + 1 for idx, cluster_id in enumerate(cluster_ids)}
    note_cluster: dict[int, str] = {}
    snippets_by_cluster: dict[str, list[str]] = defaultdict(list)
    for note in map_data.get("notes", []):
        try:
            note_idx = int(note.get("index"))
        except (TypeError, ValueError):
            continue
        cluster_id = str(note.get("clusterId") or "")
        if not cluster_id:
            continue
        note_cluster[note_idx] = cluster_id
        if len(snippets_by_cluster[cluster_id]) < MAX_LABEL_SNIPPETS:
            snippet = label_excerpt(str(note.get("snippet") or ""))
            if snippet:
                snippets_by_cluster[cluster_id].append(snippet)

    scores: dict[tuple[str, str], float] = defaultdict(float)
    for edge in map_data.get("edges", []):
        try:
            left = note_cluster[int(edge["sourceIndex"])]
            right = note_cluster[int(edge["targetIndex"])]
        except (KeyError, TypeError, ValueError):
            continue
        if left == right:
            continue
        key = (left, right) if cluster_order.get(left, 0) < cluster_order.get(right, 0) else (right, left)
        scores[key] += float(edge.get("weight") or 0.0)

    out: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for (left, right), weight in scores.items():
        out[left].append({"cluster_id": right, "cluster_index": cluster_order.get(right, 0), "weight": weight})
        out[right].append({"cluster_id": left, "cluster_index": cluster_order.get(left, 0), "weight": weight})
    for cluster_id, neighbors in list(out.items()):
        out[cluster_id] = [
            {
                "cluster_index": neighbor["cluster_index"],
                "keywords": keywords_from_snippets(snippets_by_cluster.get(neighbor["cluster_id"], []), 6),
            }
            for neighbor in sorted(neighbors, key=lambda item: (-item["weight"], item["cluster_index"]))[:4]
        ]
    return dict(out)


if __name__ == "__main__":
    raise SystemExit(main())
