from __future__ import annotations

from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import re
from typing import Any

from . import llm


STOP_WORDS = {
    "the", "and", "with", "from", "this", "that", "into", "about", "there", "their",
    "have", "has", "will", "note", "notes", "topic", "theme", "content", "markdown",
}


def build_cluster_profiles(notes: list[dict[str, Any]], assignments: list[int], node_metrics: dict[int, dict[str, float | int]], edges: list[dict[str, Any]]) -> list[dict[str, Any]]:
    members: dict[int, list[int]] = defaultdict(list)
    for idx, cid in enumerate(assignments):
        members[cid].append(idx)
    neighbors = _neighbor_clusters(assignments, edges)
    profiles = []
    for order, cid in enumerate(sorted(members, key=lambda c: (-len(members[c]), c)), start=1):
        idxs = members[cid]
        core = sorted(idxs, key=lambda idx: (-float(node_metrics[idx]["internalWeight"]), idx))[:12]
        bridge = sorted(idxs, key=lambda idx: (-float(node_metrics[idx]["bridgeScore"]), idx))[:8]
        snippets = [label_excerpt(notes[idx]["text"]) for idx in core if notes[idx].get("text")]
        keywords = keywords_from_snippets(snippets, 10)
        profiles.append({
            "clusterId": f"mountain-{order}",
            "communityId": cid,
            "coreSnippets": snippets,
            "bridgeSnippets": [label_excerpt(notes[idx]["text"]) for idx in bridge if notes[idx].get("text")],
            "topKeywords": keywords,
            "neighborClusters": neighbors.get(cid, []),
            "sourceBreakdown": dict(Counter(notes[idx]["lookup"] for idx in idxs)),
            "contrastHints": keywords[:4],
            "labelKind": "cluster",
            "signature": _profile_signature(notes, core, keywords, neighbors.get(cid, [])),
        })
    return profiles


def build_anchor_profiles(
    notes: list[dict[str, Any]],
    assignments: list[int],
    node_metrics: dict[int, dict[str, float | int]],
    peak_anchors: dict[int, list[dict[str, Any]]],
    points: Any,
) -> list[dict[str, Any]]:
    profiles = []
    for cid in sorted(peak_anchors):
        member_idxs = [idx for idx, value in enumerate(assignments) if value == cid]
        for anchor in peak_anchors.get(cid, []):
            ax = float(anchor["x"])
            ay = float(anchor["y"])
            ranked = sorted(
                member_idxs,
                key=lambda idx: (
                    ((float(points[idx, 0]) - ax) ** 2) + ((float(points[idx, 1]) - ay) ** 2),
                    -float(node_metrics[idx]["internalWeight"]),
                    idx,
                ),
            )
            local = ranked[:14]
            snippets = [label_excerpt(notes[idx]["text"]) for idx in local if notes[idx].get("text")]
            keywords = keywords_from_snippets(snippets, 10)
            rank = int(anchor.get("rank") or 1)
            profiles.append({
                "clusterId": f"mountain-{cid}",
                "communityId": cid,
                "anchorKey": f"{cid}:{rank}",
                "anchorRank": rank,
                "anchorX": ax,
                "anchorY": ay,
                "coreSnippets": snippets[:10],
                "bridgeSnippets": [],
                "topKeywords": keywords,
                "neighborClusters": [],
                "sourceBreakdown": dict(Counter(notes[idx]["lookup"] for idx in local)),
                "contrastHints": keywords[:4],
                "labelKind": "peak",
                "signature": _anchor_signature(notes, local, keywords, cid, rank, ax, ay),
            })
    return profiles


def assign_labels(config: Any, profiles: list[dict[str, Any]], cache_path: Path | None, *, max_workers: int = 4) -> dict[int, dict[str, Any]]:
    cache: dict[str, Any] = {}
    if cache_path and cache_path.exists():
        try:
            cache = json.loads(cache_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            cache = {}
    used = set()
    changed = False
    labels = {}
    pending = []
    for idx, profile in enumerate(profiles, start=1):
        sig = profile["signature"]
        cached = cache.get(sig) if isinstance(cache, dict) else None
        if isinstance(cached, dict) and cached.get("primaryLabel") and cached.get("labelSource") == "llm":
            label = _coerce_label(cached, profile["topKeywords"])
        else:
            pending.append((idx, profile, sig))
            continue
        key = _label_key(label["primaryLabel"])
        if key in used:
            pending.append((idx, profile, sig))
            continue
        used.add(key)
        labels[idx] = label

    if pending:
        print(f"Generating v2 labels with LLM: pending={len(pending)}, workers={max_workers}")
        generated: dict[int, tuple[str, dict[str, Any]]] = {}
        with ThreadPoolExecutor(max_workers=max(1, int(max_workers))) as executor:
            futures = {
                executor.submit(_generate_label, config, profile, idx, sorted(used)): (idx, profile, sig)
                for idx, profile, sig in pending
            }
            for future in as_completed(futures):
                idx, profile, sig = futures[future]
                try:
                    label = future.result()
                except Exception as exc:
                    print(f"LLM label failed for mountain {idx}: {exc.__class__.__name__}: {exc}")
                    label = fallback_label(profile["topKeywords"], idx, used)
                generated[idx] = (sig, label)

        for idx, profile, sig in pending:
            label = generated[idx][1]
            key = _label_key(label["primaryLabel"])
            if not key or key in used:
                label = _regenerate_distinct_label(config, profile, idx, used)
                key = _label_key(label["primaryLabel"])
            if not key or key in used:
                label = fallback_label(profile["topKeywords"], idx, used)
                key = _label_key(label["primaryLabel"])
            used.add(key)
            labels[idx] = label
            cache[sig] = label
            changed = True

    if cache_path and changed:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(json.dumps(cache, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return labels


def label_cache_path(output_path: Path, configured: str | None) -> Path | None:
    if configured is None:
        return output_path.with_name(f"{output_path.name}.labels.json")
    if configured.strip().lower() == "false":
        return None
    path = Path(configured)
    return path if path.is_absolute() else (output_path.parent / path).resolve()


def fallback_label(keywords: list[str], cluster_index: int, used: set[str]) -> dict[str, Any]:
    cleaned = [_clean_label(word) for word in keywords]
    cleaned = [word for word in cleaned if word]
    for word in cleaned:
        if _label_key(word) not in used:
            chips = [chip for chip in cleaned if chip != word][:3]
            return {"primaryLabel": word, "subtitle": " · ".join(chips[:3]), "keywordChips": chips[:3], "labelSource": "fallback"}
    primary = f"主题{cluster_index}"
    return {"primaryLabel": primary, "subtitle": "", "keywordChips": cleaned[:3], "labelSource": "fallback"}


def _generate_label(config: Any, profile: dict[str, Any], cluster_index: int, used_labels: list[str]) -> dict[str, Any]:
    raw = llm.chat(
        config,
        [
            {"role": llm.ROLE_SYSTEM, "content": "You output only strict JSON for a semantic mountain label."},
            {"role": llm.ROLE_USER, "content": _label_prompt(profile, cluster_index, used_labels)},
        ],
        {"temperature": 0.2},
    )
    label = _parse_llm_label(raw, profile["topKeywords"])
    if not label.get("primaryLabel"):
        raise ValueError(f"empty label from LLM: {raw[:200]}")
    label["labelSource"] = "llm"
    return label


def _regenerate_distinct_label(config: Any, profile: dict[str, Any], cluster_index: int, used: set[str]) -> dict[str, Any]:
    for attempt in range(2):
        try:
            label = _generate_label(config, profile, cluster_index, sorted(used))
        except Exception as exc:
            print(f"LLM label retry failed for mountain {cluster_index}: {exc.__class__.__name__}: {exc}")
            continue
        key = _label_key(label["primaryLabel"])
        if key and key not in used:
            return label
        print(f"LLM label retry duplicated for mountain {cluster_index}: {label['primaryLabel']} (attempt {attempt + 1})")
    return {"primaryLabel": "", "subtitle": "", "keywordChips": [], "labelSource": "fallback"}


def _label_prompt(profile: dict[str, Any], cluster_index: int, used_labels: list[str]) -> str:
    core = "\n".join(f"- {snippet}" for snippet in profile.get("coreSnippets", [])[:10])
    bridge = "\n".join(f"- {snippet}" for snippet in profile.get("bridgeSnippets", [])[:5])
    neighbors = ", ".join(str(item.get("communityId")) for item in profile.get("neighborClusters", [])[:5])
    used = ", ".join(used_labels[-20:])
    label_target = "local contour peak" if profile.get("labelKind") == "peak" else "knowledge mountain"
    context_line = (
        f"Local peak rank: {profile.get('anchorRank')}, coordinates: {profile.get('anchorX'):.1f},{profile.get('anchorY'):.1f}"
        if profile.get("labelKind") == "peak"
        else f"Cluster index: {cluster_index}"
    )
    return f"""Name one {label_target} in a personal cognition map.

Return only strict JSON:
{{"primaryLabel":"2-6 Chinese chars or 1-3 English words","subtitle":"concise phrase","keywordChips":["short","short","short"]}}

Rules:
- Prefer polished Chinese labels unless English is clearly better.
- Be specific and contrastive; avoid generic labels like 知识, 问题, 时候, 内容, 学习.
- Do not mention filenames, chunks, cluster ids, or the word mountain.
- Reuse none of these labels: {used}

{context_line}
Top keywords: {", ".join(profile.get("topKeywords", []))}
Neighbor communities: {neighbors}

Core notes:
{core}

Bridge/pass notes:
{bridge}
"""


def _parse_llm_label(raw: str, keywords: list[str]) -> dict[str, Any]:
    text = re.sub(r"<think>.*?</think>", " ", str(raw), flags=re.DOTALL | re.IGNORECASE).strip()
    parsed = _extract_json_object(text)
    primary = _clean_label(str(parsed.get("primaryLabel") or parsed.get("label") or ""))
    chips = [_clean_label(str(chip)) for chip in parsed.get("keywordChips", [])]
    chips = [chip for chip in chips if chip][:3]
    for keyword in keywords:
        if len(chips) >= 3:
            break
        chip = _clean_label(keyword)
        if chip and chip not in chips:
            chips.append(chip)
    return {"primaryLabel": primary, "subtitle": _clean_label(str(parsed.get("subtitle") or ""))[:60], "keywordChips": chips[:3]}


def _extract_json_object(text: str) -> dict[str, Any]:
    decoder = json.JSONDecoder()
    for match in re.finditer(r"\{", text):
        try:
            parsed, _end = decoder.raw_decode(text[match.start():])
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return parsed
    raise json.JSONDecodeError("No JSON object found", text, 0)


def label_excerpt(text: str, max_chars: int = 120) -> str:
    cleaned = re.sub(r"https?://\S+", " ", str(text))
    cleaned = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"\2", cleaned)
    cleaned = re.sub(r"\[\[([^\]]+)\]\]", r"\1", cleaned)
    cleaned = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", cleaned)
    cleaned = re.sub(r"`{1,3}[^`]*`{1,3}", " ", cleaned)
    cleaned = re.sub(r"[*_>#~-]", " ", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned[:max_chars].strip()


def map_snippet(text: str, max_chars: int = 360) -> str:
    cleaned = re.sub(r"\s+", " ", str(text)).strip()
    return cleaned[:max_chars].strip() + ("..." if len(cleaned) > max_chars else "")


def keywords_from_snippets(snippets: list[str], limit: int = 8) -> list[str]:
    tokens = re.findall(r"[\u4e00-\u9fff]{2,4}|[A-Za-z][A-Za-z0-9_-]{2,}", " ".join(snippets))
    counter: Counter[str] = Counter()
    for token in tokens:
        key = token if re.search(r"[\u4e00-\u9fff]", token) else token.lower()
        if key in STOP_WORDS:
            continue
        counter[key] += 1
    return [word for word, _ in counter.most_common(limit)]


def _neighbor_clusters(assignments: list[int], edges: list[dict[str, Any]]) -> dict[int, list[dict[str, Any]]]:
    scores: dict[int, dict[int, float]] = defaultdict(lambda: defaultdict(float))
    for edge in edges:
        ca = assignments[int(edge["source"])]
        cb = assignments[int(edge["target"])]
        if ca == cb:
            continue
        scores[ca][cb] += float(edge["weight"])
        scores[cb][ca] += float(edge["weight"])
    return {
        cid: [{"communityId": int(nid), "weight": float(weight)} for nid, weight in sorted(neigh.items(), key=lambda item: -item[1])[:5]]
        for cid, neigh in scores.items()
    }


def _profile_signature(notes: list[dict[str, Any]], core: list[int], keywords: list[str], neighbors: list[dict[str, Any]]) -> str:
    body = json.dumps({
        "hashes": [notes[idx].get("hash") for idx in core[:16]],
        "keywords": keywords[:12],
        "neighbors": neighbors[:5],
    }, ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def _anchor_signature(notes: list[dict[str, Any]], local: list[int], keywords: list[str], cid: int, rank: int, x: float, y: float) -> str:
    body = json.dumps({
        "kind": "peak",
        "communityId": cid,
        "rank": rank,
        "xy": [round(x / 20.0), round(y / 20.0)],
        "hashes": [notes[idx].get("hash") for idx in local[:16]],
        "keywords": keywords[:12],
    }, ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def _coerce_label(raw: dict[str, Any], keywords: list[str]) -> dict[str, Any]:
    primary = _clean_label(str(raw.get("primaryLabel") or raw.get("label") or ""))
    if not primary:
        return fallback_label(keywords, 0, set())
    chips = [_clean_label(str(chip)) for chip in raw.get("keywordChips", [])]
    chips = [chip for chip in chips if chip][:3]
    for keyword in keywords:
        if len(chips) >= 3:
            break
        chip = _clean_label(keyword)
        if chip and chip not in chips:
            chips.append(chip)
    return {
        "primaryLabel": primary,
        "subtitle": _clean_label(str(raw.get("subtitle") or ""))[:60],
        "keywordChips": chips[:3],
        "labelSource": str(raw.get("labelSource") or "llm"),
    }


def _clean_label(text: str) -> str:
    cleaned = re.sub(r"[\"'`“”‘’()\[\]{}]", " ", str(text))
    cleaned = re.sub(r"[\\/_|]+", " ", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" -:：,，.。;；")
    if re.search(r"[\u4e00-\u9fff]", cleaned):
        cleaned = re.sub(r"\s+", "", cleaned)
        return cleaned[:8]
    return " ".join(cleaned.split()[:4])[:42]


def _label_key(text: str) -> str:
    return re.sub(r"\s+", "", _clean_label(text).lower())
