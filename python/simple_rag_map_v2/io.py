from __future__ import annotations

import json
from pathlib import Path, PurePath
import sqlite3
from typing import Any

from .config import PathConfig


def load_indexed_notes(paths: list[PathConfig]) -> list[dict[str, Any]]:
    notes: list[dict[str, Any]] = []
    for path_cfg in paths:
        loaded = _load_sqlite(path_cfg)
        for note in loaded:
            note["index"] = len(notes)
            notes.append(note)
        print(f'Loaded {len(loaded)} notes from "{path_cfg.name}"')
    if not notes:
        raise RuntimeError("No notes available. Run run-index first or adjust map.includePaths.")
    return notes


def _load_sqlite(path_cfg: PathConfig) -> list[dict[str, Any]]:
    db_path = Path(str(path_cfg.db_file)).expanduser()
    if not db_path.exists():
        return []
    quoted = '"' + str(path_cfg.db_table).replace('"', '""') + '"'
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        notes = [
            _note_from_row(path_cfg, row)
            for row in conn.execute(f"SELECT path, chunk, hash, embedding, bucket, text FROM {quoted}")
            if _row_get(row, "embedding")
        ]
    finally:
        conn.close()
    return notes


def parse_embedding(raw: Any) -> list[float]:
    if isinstance(raw, list):
        values = raw
    elif isinstance(raw, bytes):
        values = json.loads(raw.decode("utf-8"))
    else:
        values = json.loads(str(raw))
    return [float(value) for value in values]


def _note_from_row(path_cfg: PathConfig, row: Any) -> dict[str, Any]:
    file_path = str(_row_get(row, "path"))
    chunk = int(_row_get(row, "chunk"))
    text = str(_row_get(row, "text", "") or "")
    return {
        "index": -1,
        "lookup": path_cfg.name,
        "path": file_path,
        "chunk": chunk,
        "hash": str(_row_get(row, "hash", "")),
        "title": _title(file_path),
        "url": _url(file_path, path_cfg.url),
        "text": text,
        "embedding": parse_embedding(_row_get(row, "embedding")),
    }


def _row_get(row: Any, key: str, default: Any = None) -> Any:
    if isinstance(row, dict):
        return row.get(key, default)
    try:
        return row[key]
    except (KeyError, IndexError):
        return default


def _title(file_path: str) -> str:
    parts = PurePath(file_path).parts
    if len(parts) >= 2:
        return str(PurePath(*parts[-2:])).replace("\\", "/")
    return Path(file_path).name


def _url(file_path: str, url_prefix: str | None) -> str:
    if url_prefix:
        return f"{url_prefix}{Path(file_path).stem}"
    return f"file://{file_path}"
