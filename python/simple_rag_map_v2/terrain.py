from __future__ import annotations

from typing import Any

import numpy as np
from scipy.ndimage import maximum_filter
from skimage import measure

from .config import TerrainConfig
def build_terrain(points: np.ndarray, density_weights: dict[int, float], config: TerrainConfig, *, width: int, height: int) -> dict[str, Any]:
    xs = np.arange(0, width + config.cell_size, config.cell_size, dtype=float)
    ys = np.arange(0, height + config.cell_size, config.cell_size, dtype=float)
    grid = np.zeros((len(ys), len(xs)), dtype=float)
    sigma2 = 2.0 * config.sigma * config.sigma
    radius = max(config.cell_size, config.sigma * 3.0)
    for idx, (x, y) in enumerate(points):
        xmin = max(0, int((x - radius) // config.cell_size))
        xmax = min(len(xs) - 1, int((x + radius) // config.cell_size) + 1)
        ymin = max(0, int((y - radius) // config.cell_size))
        ymax = min(len(ys) - 1, int((y + radius) // config.cell_size) + 1)
        local_x = xs[xmin : xmax + 1]
        local_y = ys[ymin : ymax + 1]
        dx2 = (local_x[None, :] - x) ** 2
        dy2 = (local_y[:, None] - y) ** 2
        grid[ymin : ymax + 1, xmin : xmax + 1] += float(density_weights.get(idx, 1.0)) * np.exp(-(dx2 + dy2) / sigma2)
    max_density = float(np.max(grid)) if grid.size else 0.0
    level_items = []
    if max_density > 0 and config.embed_contours:
        ratios = _ratios(config.levels, config.lowest_ratio, config.highest_ratio)
        for pos, ratio in enumerate(ratios):
            level = max_density * ratio
            segments = []
            for contour in measure.find_contours(grid, level):
                if len(contour) < 2:
                    continue
                coords = []
                for row, col in contour:
                    coords.append([round(float(col * config.cell_size), 2), round(float(row * config.cell_size), 2)])
                for left, right in zip(coords, coords[1:]):
                    segments.append([left[0], left[1], right[0], right[1]])
            level_items.append({
                "ratio": float(ratio),
                "level": float(level),
                "major": pos % 4 == 0 or pos == len(ratios) - 1,
                "segments": segments,
            })
    return {
        "cellSize": config.cell_size,
        "sigma": config.sigma,
        "maxDensity": max_density,
        "levels": level_items,
    }


def cluster_peak_anchors(
    points: np.ndarray,
    assignments: list[int],
    density_weights: dict[int, float],
    config: TerrainConfig,
    *,
    max_anchors_per_cluster: int = 3,
) -> dict[int, list[dict[str, Any]]]:
    anchors: dict[int, list[dict[str, Any]]] = {}
    for cid in sorted(set(assignments)):
        idxs = [idx for idx, value in enumerate(assignments) if value == cid]
        if not idxs:
            anchors[cid] = []
            continue
        cluster_points = points[idxs]
        if len(idxs) == 1:
            anchors[cid] = [{"x": float(cluster_points[0, 0]), "y": float(cluster_points[0, 1]), "density": 1.0, "rank": 1}]
            continue
        anchors[cid] = _cluster_peak_anchors_for_points(
            cluster_points,
            [float(density_weights.get(idx, 1.0)) for idx in idxs],
            config,
            max_anchors=max_anchors_per_cluster,
        )
    return anchors


def _cluster_peak_anchors_for_points(points: np.ndarray, weights: list[float], config: TerrainConfig, *, max_anchors: int) -> list[dict[str, Any]]:
    sigma = float(config.sigma)
    cell = float(config.cell_size)
    radius = max(cell, sigma * 3.0)
    origin_x = float(np.min(points[:, 0]) - radius)
    origin_y = float(np.min(points[:, 1]) - radius)
    max_x = float(np.max(points[:, 0]) + radius)
    max_y = float(np.max(points[:, 1]) + radius)
    xs = np.arange(origin_x, max_x + cell, cell, dtype=float)
    ys = np.arange(origin_y, max_y + cell, cell, dtype=float)
    grid = np.zeros((len(ys), len(xs)), dtype=float)
    sigma2 = 2.0 * sigma * sigma
    for (x, y), weight in zip(points, weights):
        xmin = max(0, int((x - radius - origin_x) // cell))
        xmax = min(len(xs) - 1, int((x + radius - origin_x) // cell) + 1)
        ymin = max(0, int((y - radius - origin_y) // cell))
        ymax = min(len(ys) - 1, int((y + radius - origin_y) // cell) + 1)
        local_x = xs[xmin : xmax + 1]
        local_y = ys[ymin : ymax + 1]
        dx2 = (local_x[None, :] - x) ** 2
        dy2 = (local_y[:, None] - y) ** 2
        grid[ymin : ymax + 1, xmin : xmax + 1] += float(weight) * np.exp(-(dx2 + dy2) / sigma2)

    max_density = float(np.max(grid)) if grid.size else 0.0
    if max_density <= 0:
        center = np.mean(points, axis=0)
        return [{"x": float(center[0]), "y": float(center[1]), "density": 0.0, "rank": 1}]

    neighborhood = max(3, int(round((sigma * 1.45) / cell)))
    local_max = grid == maximum_filter(grid, size=neighborhood, mode="nearest")
    candidates = np.argwhere(local_max & (grid >= max_density * 0.38))
    ranked = sorted(candidates, key=lambda rc: float(grid[int(rc[0]), int(rc[1])]), reverse=True)

    selected: list[dict[str, Any]] = []
    min_distance = max(130.0, sigma * 3.2)
    min_distance2 = min_distance * min_distance
    for row, col in ranked:
        x = float(xs[int(col)])
        y = float(ys[int(row)])
        if any(((x - item["x"]) ** 2) + ((y - item["y"]) ** 2) < min_distance2 for item in selected):
            continue
        selected.append({"x": x, "y": y, "density": float(grid[int(row), int(col)]), "rank": len(selected) + 1})
        if len(selected) >= max_anchors:
            break

    if not selected:
        row, col = np.unravel_index(int(np.argmax(grid)), grid.shape)
        selected.append({"x": float(xs[int(col)]), "y": float(ys[int(row)]), "density": max_density, "rank": 1})
    return selected


def _ratios(count: int, lowest: float, highest: float) -> list[float]:
    lowest = max(1e-5, min(lowest, 0.95))
    highest = max(lowest + 1e-5, min(highest, 0.999))
    t = np.linspace(0.0, 1.0, count)
    curved = t ** 0.68
    return [float(lowest * ((highest / lowest) ** value)) for value in curved]
