from __future__ import annotations

import json
from pathlib import Path
import sys
from typing import Any

from .config import Config, load_config, map_value
from .labels import Labeler
from .llm import ensure_ollama_started, missing_key_message, should_start_ollama
from .pipeline import build_map_data, load_all_notes


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) < 1 or len(argv) > 2:
        print("Invalid arguments received, need a config file and optional path names")
        return 1

    config_file = Path(argv[0]).resolve()
    config_base_dir = config_file.parent
    cli_include_raw = argv[1] if len(argv) == 2 else None

    try:
        config = load_config(config_file)
    except Exception as exc:
        print(f"Config error: {exc}")
        return 1

    missing = missing_key_message(config)
    if missing:
        print(missing)
        return 9

    try:
        map_out_file = map_out_file_required(config, config_base_dir)
        if should_start_ollama(config) and not ensure_ollama_started(config):
            return 9
        target_paths = resolve_target_paths(config, cli_include_raw)
        print(f"Selected paths: {', '.join(path.name for path in target_paths)}")
        notes = load_all_notes(target_paths)
        labeler = Labeler(config, label_cache_path(config, map_out_file))
        map_data = build_map_data(config, notes, labeler)
        map_out_file.parent.mkdir(parents=True, exist_ok=True)
        map_out_file.write_text(json.dumps(map_data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"Map data generated: {map_out_file}")
        print(f"Notes: {map_data['noteCount']}, mountains: {len(map_data['clusters'])}, vector_dim: {map_data['vectorDim']}")
        return 0
    except Exception as exc:
        print(f"run-index-map failed: {exc.__class__.__name__}: {exc}")
        return 1


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


if __name__ == "__main__":
    raise SystemExit(main())
