from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import re
from typing import Any


TABLE_NAME_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
DB_FORMAT = '"sqlite_file_path@table_name"'


@dataclass(slots=True)
class PathConfig:
    name: str
    reader: str | None
    db: str | None
    db_file: str | None
    db_table: str | None
    url: str | None
    raw: dict[str, Any]


@dataclass(slots=True)
class Config:
    raw: dict[str, Any]
    paths: list[PathConfig]


def load_config(config_path: str | Path) -> Config:
    with Path(config_path).open("r", encoding="utf-8") as fh:
        raw = json.load(fh)

    paths = [
        _normalize_path(path_raw, idx + 1)
        for idx, path_raw in enumerate(raw.get("paths") or [])
    ]
    return Config(raw=raw, paths=paths)


def config_value(config: Config, section: str, key: str, default: Any = None) -> Any:
    section_data = config.raw.get(section)
    if not isinstance(section_data, dict):
        return default
    return section_data.get(key, default)


def provider_name(config: Config, section: str) -> str:
    provider = config_value(config, section, "provider", "")
    return str(provider).strip().lower()


def map_value(config: Config, key: str, default: Any = None) -> Any:
    return config_value(config, "map", key, default)


def parse_db_target(raw_db: Any, path_name: str) -> tuple[str | None, str | None]:
    if raw_db is None or str(raw_db).strip() == "":
        return None, None

    db_target = str(raw_db).strip()
    parts = db_target.split("@")
    if len(parts) != 2 or not parts[0] or not parts[1]:
        raise ValueError(f'Invalid db for path "{path_name}": "{db_target}". Expected {DB_FORMAT}.')

    table_name = parts[1]
    if not TABLE_NAME_PATTERN.match(table_name):
        raise ValueError(
            f'Invalid db table for path "{path_name}": "{table_name}". '
            "Use letters, digits, and underscores only, and start with a letter or underscore."
        )
    return parts[0], table_name


def _normalize_path(path_raw: dict[str, Any], fallback_idx: int) -> PathConfig:
    path_name = path_raw.get("name") or f"paths[{fallback_idx}]"
    db_file, db_table = parse_db_target(path_raw.get("db"), path_name)

    if db_file is None:
        raise ValueError(f'Path "{path_name}" must set "db".')

    return PathConfig(
        name=str(path_name),
        reader=path_raw.get("reader"),
        db=str(path_raw.get("db")) if path_raw.get("db") is not None else None,
        db_file=db_file,
        db_table=db_table,
        url=str(path_raw.get("url")) if path_raw.get("url") is not None else None,
        raw=path_raw,
    )
