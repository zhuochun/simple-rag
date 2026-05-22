from __future__ import annotations

from typing import Any

import numpy as np


def validate_and_normalize(notes: list[dict[str, Any]]) -> tuple[np.ndarray, int, dict[str, Any]]:
    if not notes:
        raise RuntimeError("No notes available.")
    arrays = []
    dim = None
    norms = []
    for idx, note in enumerate(notes):
        embedding = note.get("embedding")
        if not embedding:
            raise RuntimeError(f"Missing embedding for note index {idx} ({note.get('path')}#{note.get('chunk')})")
        arr = np.asarray(embedding, dtype=np.float32)
        if arr.ndim != 1:
            raise RuntimeError(f"Invalid embedding shape for note index {idx}")
        if dim is None:
            dim = int(arr.shape[0])
        elif int(arr.shape[0]) != dim:
            raise RuntimeError(
                f"Embedding dimension mismatch: expected={dim}, got={arr.shape[0]}, note={note.get('path')}#{note.get('chunk')}"
            )
        norm = float(np.linalg.norm(arr))
        if norm <= 1e-12:
            raise RuntimeError(f"Zero-norm embedding at {note.get('path')}#{note.get('chunk')}")
        norms.append(norm)
        arrays.append(arr / norm)
    matrix = np.vstack(arrays).astype(np.float32)
    for idx, note in enumerate(notes):
        note["embedding"] = matrix[idx].tolist()
    stats = {
        "noteCount": len(notes),
        "vectorDim": int(dim or 0),
        "normMin": float(min(norms)),
        "normMax": float(max(norms)),
        "normMean": float(sum(norms) / len(norms)),
    }
    return matrix, int(dim or 0), stats
