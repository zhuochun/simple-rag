from __future__ import annotations

from dataclasses import dataclass, field
import json
from pathlib import Path
import re
from typing import Any


TABLE_NAME_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


@dataclass(slots=True)
class PathConfig:
    name: str
    reader: str | None
    db_file: str | None
    db_table: str | None
    url: str | None
    raw: dict[str, Any]


@dataclass(slots=True)
class SemanticLayoutConfig:
    method: str = "umap"
    n_neighbors: int = 40
    min_dist: float = 0.08
    metric: str = "cosine"
    random_state: int = 42


@dataclass(slots=True)
class CartographyConfig:
    mountain_separation: float = 1.15
    mountain_shape_strength: float = 0.82
    bridge_blend: float = 0.65
    core_packing: float = 0.72
    foothill_spread: float = 1.18


@dataclass(slots=True)
class TerrainConfig:
    cell_size: int = 10
    sigma: float = 34.0
    levels: int = 22
    lowest_ratio: float = 0.035
    highest_ratio: float = 0.88
    embed_contours: bool = True


@dataclass(slots=True)
class LabelConfig:
    enabled: bool = True
    label_workers: int = 4
    label_cache_path: str | None = None


@dataclass(slots=True)
class MapV2Config:
    output_path: Path
    include_paths: list[str] | None
    knn_k: int = 50
    community_resolution: float = 0.8
    min_community_size: int = 12
    random_state: int = 42
    semantic_layout: SemanticLayoutConfig = field(default_factory=SemanticLayoutConfig)
    cartography: CartographyConfig = field(default_factory=CartographyConfig)
    terrain: TerrainConfig = field(default_factory=TerrainConfig)
    labels: LabelConfig = field(default_factory=LabelConfig)


@dataclass(slots=True)
class Config:
    raw: dict[str, Any]
    config_path: Path
    paths: list[PathConfig]
    map_v2: MapV2Config


def load_config(config_path: str | Path, *, seed: int | None = None, label_workers: int | None = None) -> Config:
    path = Path(config_path).resolve()
    raw = json.loads(path.read_text(encoding="utf-8"))
    paths = [_normalize_path(item, idx + 1) for idx, item in enumerate(raw.get("paths") or [])]
    map_cfg = _map_v2_config(raw, path.parent, seed=seed, label_workers=label_workers)
    return Config(raw=raw, config_path=path, paths=paths, map_v2=map_cfg)


def selected_paths(config: Config, include_arg: str | None) -> list[PathConfig]:
    names = _parse_include_arg(include_arg) or config.map_v2.include_paths
    if not names:
        return config.paths
    known = {path.name for path in config.paths}
    missing = [name for name in names if name not in known]
    if missing:
        raise ValueError(f"Unknown path names in include filter: {', '.join(missing)}")
    out = [path for path in config.paths if path.name in set(names)]
    if not out:
        raise ValueError("No paths selected for map generation")
    return out


def _map_v2_config(raw: dict[str, Any], base_dir: Path, *, seed: int | None, label_workers: int | None) -> MapV2Config:
    map_raw = raw.get("map") if isinstance(raw.get("map"), dict) else {}
    v2_raw = map_raw.get("v2") if isinstance(map_raw.get("v2"), dict) else {}
    semantic_raw = v2_raw.get("semanticLayout") if isinstance(v2_raw.get("semanticLayout"), dict) else {}
    cart_raw = v2_raw.get("cartography") if isinstance(v2_raw.get("cartography"), dict) else {}
    terrain_raw = v2_raw.get("terrain") if isinstance(v2_raw.get("terrain"), dict) else {}
    labels_raw = v2_raw.get("labels") if isinstance(v2_raw.get("labels"), dict) else {}

    output_raw = str(map_raw.get("path") or "map_data.json").strip()
    output_path = Path(output_raw)
    if not output_path.is_absolute():
        output_path = (base_dir / output_path).resolve()

    random_state = int(seed if seed is not None else semantic_raw.get("randomState", v2_raw.get("randomState", 42)))
    semantic = SemanticLayoutConfig(
        method=str(semantic_raw.get("method", "umap")).lower(),
        n_neighbors=max(2, int(semantic_raw.get("nNeighbors", 40))),
        min_dist=float(semantic_raw.get("minDist", 0.08)),
        metric=str(semantic_raw.get("metric", "cosine")),
        random_state=random_state,
    )
    labels = LabelConfig(
        enabled=_bool_config(labels_raw.get("enabled", True)),
        label_workers=max(1, int(label_workers if label_workers is not None else labels_raw.get("labelWorkers", 4))),
        label_cache_path=str(labels_raw.get("labelCachePath")).strip() if labels_raw.get("labelCachePath") else None,
    )
    return MapV2Config(
        output_path=output_path,
        include_paths=_parse_include_value(map_raw.get("includePaths")),
        knn_k=max(1, int(v2_raw.get("knnK", 50))),
        community_resolution=float(v2_raw.get("communityResolution", 0.8)),
        min_community_size=max(1, int(v2_raw.get("minCommunitySize", 12))),
        random_state=random_state,
        semantic_layout=semantic,
        cartography=CartographyConfig(
            mountain_separation=float(cart_raw.get("mountainSeparation", 1.15)),
            mountain_shape_strength=float(cart_raw.get("mountainShapeStrength", 0.82)),
            bridge_blend=float(cart_raw.get("bridgeBlend", 0.65)),
            core_packing=float(cart_raw.get("corePacking", 0.72)),
            foothill_spread=float(cart_raw.get("foothillSpread", 1.18)),
        ),
        terrain=TerrainConfig(
            cell_size=max(2, int(terrain_raw.get("cellSize", 10))),
            sigma=max(1.0, float(terrain_raw.get("sigma", 34))),
            levels=max(3, int(terrain_raw.get("levels", 22))),
            lowest_ratio=float(terrain_raw.get("lowestRatio", 0.035)),
            highest_ratio=float(terrain_raw.get("highestRatio", 0.88)),
            embed_contours=_bool_config(terrain_raw.get("embedContours", True)),
        ),
        labels=labels,
    )


def _bool_config(raw: Any) -> bool:
    if isinstance(raw, bool):
        return raw
    if raw is None:
        return False
    text = str(raw).strip().lower()
    if text in {"false", "0", "no", "off", "disabled"}:
        return False
    if text in {"true", "1", "yes", "on", "enabled"}:
        return True
    return bool(raw)


def _normalize_path(raw: dict[str, Any], fallback_idx: int) -> PathConfig:
    name = str(raw.get("name") or f"paths[{fallback_idx}]")
    db_file, db_table = _parse_db(raw.get("db"), name)
    if not db_file:
        raise ValueError(f'Path "{name}" must set "db".')
    return PathConfig(
        name=name,
        reader=str(raw.get("reader")) if raw.get("reader") is not None else None,
        db_file=db_file,
        db_table=db_table,
        url=str(raw.get("url")) if raw.get("url") is not None else None,
        raw=raw,
    )


def _parse_db(raw_db: Any, path_name: str) -> tuple[str | None, str | None]:
    if raw_db is None or str(raw_db).strip() == "":
        return None, None
    parts = str(raw_db).strip().split("@")
    if len(parts) != 2 or not parts[0] or not parts[1]:
        raise ValueError(f'Invalid db for path "{path_name}": expected "sqlite_file_path@table_name"')
    if not TABLE_NAME_PATTERN.match(parts[1]):
        raise ValueError(f'Invalid db table for path "{path_name}": {parts[1]}')
    return parts[0], parts[1]


def _parse_include_arg(raw: str | None) -> list[str] | None:
    if raw is None or str(raw).strip() == "":
        return None
    text = str(raw).strip()
    if text.startswith("["):
        return _parse_include_value(json.loads(text))
    return _parse_include_value(text.split(","))


def _parse_include_value(raw: Any) -> list[str] | None:
    if raw is None:
        return None
    values = raw if isinstance(raw, list) else [raw]
    names = list(dict.fromkeys(str(item).strip() for item in values if str(item).strip()))
    return names or None
