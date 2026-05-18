from __future__ import annotations

from collections import Counter
import hashlib
import html
import json
from pathlib import Path
import re
import time
from typing import Any

from . import llm
from .config import Config


MAX_LABEL_SNIPPETS = 12
MAX_LABEL_CHARS = 100
MAX_LABEL_ATTEMPTS = 3

STOP_WORDS = {
    "the", "and", "with", "from", "this", "that", "into", "about", "over", "under",
    "for", "not", "are", "was", "were", "been", "then", "than", "when", "where",
    "while", "what", "your", "you", "ours", "itself", "also", "have", "has", "had",
    "will", "they", "them", "their", "there", "here", "should", "could", "would",
    "can", "cannot", "etc", "markdown", "notes", "note", "todo", "task", "today",
    "yesterday", "tomorrow", "after", "before", "above", "below", "around", "key",
    "need", "road", "win", "thing", "idea", "topic", "theme", "concept", "content",
    "point", "issue", "summary", "every", "time", "elaborate", "usability", "tests",
    "chatgpt", "gpt", "prompt", "waste", "resources",
}

GENERIC_LABEL_WORDS = {
    "win", "key", "need", "road", "attentio", "affirm", "keyevent", "greatapi",
    "response", "event", "thing", "idea", "topic", "theme", "concept", "content",
    "point", "issue", "summary", "every", "time", "elaborate", "usability", "tests",
    "chatgpt", "gpt", "prompt", "waste", "resources",
}

GENERIC_CHINESE_LABEL_FRAGMENTS = (
    "它是", "一种", "这个", "那个", "我们", "他们", "你们", "但是", "如果", "因为", "所以",
    "需要", "可以", "通过", "对于", "关于", "时候", "进行", "可能", "重要", "做事",
    "和学习", "学习时", "干啥", "和几", "智信", "活企", "活下去", "建立自己", "如何",
    "永远是企", "永远是", "问题库", "死胡同", "过程性解", "避免陷入", "联系到",
)


class Labeler:
    def __init__(self, config: Config, cache_path: Path | None):
        self.config = config
        self.cache_path = cache_path
        self.cache: dict[str, dict[str, Any]] = {}
        self.dirty = False
        if cache_path and cache_path.exists():
            try:
                data = json.loads(cache_path.read_text(encoding="utf-8"))
                if isinstance(data, dict):
                    self.cache = {str(k): v for k, v in data.items() if isinstance(v, dict)}
            except (OSError, json.JSONDecodeError):
                self.cache = {}

    def save(self) -> None:
        if not self.cache_path or not self.dirty:
            return
        self.cache_path.parent.mkdir(parents=True, exist_ok=True)
        self.cache_path.write_text(json.dumps(self.cache, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    def generate_cluster_labels(self, cluster_samples: list[dict[str, Any]]) -> dict[int, dict[str, Any]]:
        labels: dict[int, dict[str, Any]] = {}
        used_label_keys: set[str] = set()
        used_label_texts: list[str] = []
        for sample in cluster_samples:
            cluster_index = int(sample["cluster_index"])
            cache_key = self._cache_key(sample)
            cached = self.cache.get(cache_key)
            if cached:
                label = self._coerce_label(cached, sample["keywords"])
                if label and label_key(label["primaryLabel"]) not in used_label_keys:
                    labels[cluster_index] = label
                    used_label_keys.add(label_key(label["primaryLabel"]))
                    used_label_texts.append(label["primaryLabel"])
                    continue

            assigned = self._generate_one(sample, used_label_keys, used_label_texts)
            labels[cluster_index] = assigned
            used_label_keys.add(label_key(assigned["primaryLabel"]))
            used_label_texts.append(assigned["primaryLabel"])
            self.cache[cache_key] = assigned
            self.dirty = True
        self.save()
        return labels

    def _generate_one(self, sample: dict[str, Any], used_label_keys: set[str], used_label_texts: list[str]) -> dict[str, Any]:
        rejected: list[str] = []
        cluster_index = sample["cluster_index"]
        for attempt in range(1, MAX_LABEL_ATTEMPTS + 1):
            raw_response = None
            try:
                prompt = build_label_prompt(sample, used_label_texts, rejected, attempt)
                raw_response = llm.chat(
                    self.config,
                    [
                        {"role": llm.ROLE_SYSTEM, "content": "You output only strict JSON for the final map label."},
                        {"role": llm.ROLE_USER, "content": prompt},
                    ],
                )
                label = sanitize_label_details(raw_response, sample["keywords"])
                if not label or not label.get("primaryLabel"):
                    add_rejected_label(rejected, raw_response)
                    log_label_warning(f"Empty label from LLM for cluster {cluster_index} (attempt {attempt}/{MAX_LABEL_ATTEMPTS})", response=raw_response)
                    continue
                key = label_key(label["primaryLabel"])
                if key in used_label_keys:
                    add_rejected_label(rejected, label["primaryLabel"])
                    log_label_warning(f"Duplicate label from LLM for cluster {cluster_index}: {label['primaryLabel']} (attempt {attempt}/{MAX_LABEL_ATTEMPTS})", response=raw_response)
                    continue
                return label
            except Exception as exc:
                if raw_response is not None:
                    add_rejected_label(rejected, raw_response)
                log_label_warning(f"LLM label generation failed for cluster {cluster_index} (attempt {attempt}/{MAX_LABEL_ATTEMPTS})", response=raw_response, exception=exc)

        primary = fallback_label(sample["snippets"], int(cluster_index), used_label_keys)
        label = {"primaryLabel": primary, "subtitle": "", "keywordChips": sample["keywords"][:3]}
        log_label_warning(f"Using fallback label for cluster {cluster_index}: {primary}")
        return label

    @staticmethod
    def _cache_key(sample: dict[str, Any]) -> str:
        body = json.dumps(
            {
                "snippets": sample.get("snippets", []),
                "keywords": sample.get("keywords", []),
                "neighbors": sample.get("neighbors", []),
            },
            ensure_ascii=False,
            sort_keys=True,
        )
        return hashlib.sha256(body.encode("utf-8")).hexdigest()

    @staticmethod
    def _coerce_label(raw: dict[str, Any], fallback_keywords: list[str]) -> dict[str, Any] | None:
        primary = sanitize_label(raw.get("primaryLabel") or raw.get("label") or "")
        if not primary:
            return None
        chips = [clean_label_fragment(str(chip)).strip() for chip in raw.get("keywordChips", [])]
        chips = [chip for chip in chips if chip][:3]
        for keyword in fallback_keywords:
            if len(chips) >= 3:
                break
            chip = clean_label_fragment(keyword).strip()
            if chip and chip not in chips:
                chips.append(chip)
        return {
            "primaryLabel": primary,
            "subtitle": clean_label_fragment(str(raw.get("subtitle") or ""))[:60],
            "keywordChips": chips[:3],
        }


def log_label_warning(reason: str, response: str | None = None, exception: Exception | None = None) -> None:
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    lines = [f"[LabelWarning {stamp}] {reason}"]
    if exception:
        lines.append(f"Exception: {exception.__class__.__name__}: {exception}")
    if response and str(response).strip():
        clipped = str(response)
        if len(clipped) > 2400:
            clipped = clipped[:2400] + "...(truncated)"
        lines.append(f"LLM response: {clipped}")
    print("\n".join(lines))


def label_excerpt(text: str, max_chars: int = MAX_LABEL_CHARS) -> str:
    raw = strip_model_artifacts(str(text))
    raw = re.sub(r"https?://\S+", " ", raw)
    raw = re.sub(r"\[\[[^\]|]+?\|([^\]]+)\]\]", r"\1", raw)
    raw = re.sub(r"\[\[([^\]]+)\]\]", r"\1", raw)
    raw = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", raw)
    raw = re.sub(r"`{1,3}[^`]*`{1,3}", " ", raw)
    raw = re.sub(r"<[^>]+>", " ", raw)
    raw = re.sub(r"[*_~]", " ", raw)
    lines = [line.strip() for line in raw.splitlines() if line.strip()]
    while lines and re.match(r"^#{1,6}\s+", lines[0]):
        lines.pop(0)
    cleaned = "\n".join(lines)
    cleaned = re.sub(r"^[-*+]\s+", "", cleaned)
    cleaned = re.sub(r"#{1,6}\s*", "", cleaned)
    cleaned = re.sub(r"[>]+", " ", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    if not cleaned:
        return ""
    first_sentence_match = re.match(r"^.*?[。.!?！？]", cleaned)
    first_sentence = first_sentence_match.group(0) if first_sentence_match else None
    first_line = re.sub(r"\s+", " ", re.sub(r"#{1,6}\s*", "", re.sub(r"^[-*+]\s+", "", lines[0] if lines else ""))).strip()
    candidates = [candidate.strip() for candidate in (first_sentence, first_line, cleaned[:max_chars]) if candidate and candidate.strip()]
    candidate = min(candidates, key=len) if candidates else ""
    candidate = re.sub(r"\s+", " ", candidate).strip()
    return candidate[:max_chars].strip() if len(candidate) > max_chars else candidate


def map_snippet(text: str, max_chars: int = 360) -> str:
    raw = re.sub(r"\s+", " ", strip_model_artifacts(str(text))).strip()
    if not raw:
        return ""
    return raw[:max_chars].strip() + "..." if len(raw) > max_chars else raw


def keywords_from_snippets(snippets: list[str], limit: int = 6) -> list[str]:
    tokens = re.findall(r"[\u4e00-\u9fff]{2,4}|[A-Za-z][A-Za-z0-9_-]{2,}", " ".join(snippets))
    freq: Counter[str] = Counter()
    for token in tokens:
        key = token if re.search(r"[\u4e00-\u9fff]", token) else token.lower()
        if key in STOP_WORDS:
            continue
        if re.search(r"[\u4e00-\u9fff]", key) and any(fragment in key for fragment in GENERIC_CHINESE_LABEL_FRAGMENTS):
            continue
        freq[key] += 1
    return [word for word, _count in freq.most_common(limit)]


def strip_model_artifacts(text: str) -> str:
    text = re.sub(r"<think>.*?</think>", " ", str(text), flags=re.IGNORECASE | re.DOTALL)
    text = re.sub(r"</?think>", " ", text, flags=re.IGNORECASE)
    return re.sub(r"<\|[^>]*\|>", "\n", text)


def clean_label_fragment(text: str) -> str:
    cleaned = strip_model_artifacts(str(text))
    cleaned = re.sub(r"<[^>]+>", " ", cleaned)
    cleaned = re.sub(r"([a-z])([A-Z])", r"\1 \2", cleaned)
    cleaned = re.sub(r"\b(?:label|name|title)\s*[:：]\s*", " ", cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"[\"'`“”‘’]", "", cleaned)
    cleaned = re.sub(r"[()\[\]{}]", " ", cleaned)
    cleaned = re.sub(r"[\\/_|]+", " ", cleaned)
    cleaned = re.sub(r"\bapi\b", "API", cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    cleaned = re.sub(r"([\u4e00-\u9fff])\s+([\u4e00-\u9fff])", r"\1\2", cleaned)
    return re.sub(r"^[-:：,，.。;；\s]+|[-:：,，.。;；\s]+$", "", cleaned)


def usable_label(label: str) -> bool:
    cleaned = str(label).strip()
    if not cleaned or re.search(r"[<>]", cleaned) or re.search(r"https?:|www\.|```", cleaned, re.IGNORECASE):
        return False
    if re.search(r"\b(?:cluster|mountain|label|note|filename|untitled)\b", cleaned, re.IGNORECASE):
        return False
    words = [word.lower() for word in re.findall(r"[A-Za-z][A-Za-z0-9]*", cleaned)]
    han_count = len(re.findall(r"[\u4e00-\u9fff]", cleaned))
    normalized = re.sub(r"\s+", "", cleaned.lower())
    if normalized in GENERIC_LABEL_WORDS or any(word in GENERIC_LABEL_WORDS for word in words):
        return False
    if han_count >= 2:
        if len(cleaned) > 6 or any(fragment in cleaned for fragment in GENERIC_CHINESE_LABEL_FRAGMENTS):
            return False
        if "和" in cleaned or cleaned.endswith(("几", "时", "但", "简")):
            return False
        return True
    if len(words) == 1 and len(cleaned) < 5:
        return False
    if words:
        return len(words) <= 5 and len(cleaned) <= 36
    return len(cleaned) <= 24


def sanitize_label(label: str) -> str:
    fragments = [
        clean_label_fragment(fragment)
        for fragment in re.split(r"[\r\n]+|[。.!?！？；;]+", strip_model_artifacts(str(label)))
    ]
    fragments = [fragment for fragment in fragments if fragment]
    cleaned = next((fragment for fragment in fragments if usable_label(fragment)), fragments[0] if fragments else "")
    cleaned = clean_label_fragment(cleaned)
    if not usable_label(cleaned):
        return ""
    words = re.findall(r"[A-Za-z][A-Za-z0-9]*", cleaned)
    if len(words) > 5:
        cleaned = " ".join(words[:5])
    return cleaned[:42].strip()


def label_key(label: str) -> str:
    return re.sub(r"\s+", "", clean_label_fragment(label).lower())


def add_rejected_label(rejected_labels: list[str], candidate: str) -> None:
    cleaned = clean_label_fragment(str(candidate))[:42].strip()
    key = label_key(cleaned)
    if key and not any(label_key(existing) == key for existing in rejected_labels):
        rejected_labels.append(cleaned)


def fallback_label(snippets: list[str], cluster_index: int, used_labels: set[str]) -> str:
    keywords = keywords_from_snippets(snippets, 10)
    words = [word for word in keywords if re.search(r"[\u4e00-\u9fff]", word)]
    words.extend(word for word in keywords if not re.search(r"[\u4e00-\u9fff]", word))
    for word in words:
        label = sanitize_label(word)
        if label and label_key(label) not in used_labels:
            return label
    english = [word for word in keywords if not re.search(r"[\u4e00-\u9fff]", word)][:3]
    if english:
        label = sanitize_label(" ".join(english))
        if label and label_key(label) not in used_labels:
            return label
    return f"主题{cluster_index}"


def sanitize_label_details(raw_response: str, fallback_keywords: list[str]) -> dict[str, Any] | None:
    try:
        parsed = json.loads(strip_model_artifacts(str(raw_response)))
        primary = sanitize_label(parsed.get("primaryLabel") or "")
        if not primary:
            return None
        subtitle = clean_label_fragment(str(parsed.get("subtitle") or ""))[:60]
        chips = [clean_label_fragment(str(chip)).strip() for chip in parsed.get("keywordChips") or []]
        chips = [chip for chip in chips if chip][:3]
    except (json.JSONDecodeError, TypeError, AttributeError):
        primary = sanitize_label(str(raw_response))
        if not primary:
            return None
        subtitle = ""
        chips = []
    for keyword in fallback_keywords:
        if len(chips) >= 3:
            break
        chip = clean_label_fragment(keyword).strip()
        if chip and chip not in chips:
            chips.append(chip)
    return {"primaryLabel": primary, "subtitle": subtitle, "keywordChips": chips[:3]}


def build_label_prompt(sample: dict[str, Any], used_labels: list[str], rejected_labels: list[str], attempt: int) -> str:
    notes_xml = "\n".join(
        f'    <note rank="{idx + 1}">{html.escape(snippet, quote=True)}</note>'
        for idx, snippet in enumerate(sample["snippets"])
    )
    used_xml = "\n".join(f"    <label>{html.escape(label, quote=True)}</label>" for label in used_labels[-24:])
    rejected_xml = "\n".join(f"    <label>{html.escape(label, quote=True)}</label>" for label in rejected_labels[-12:])
    neighbors_xml = "\n".join(
        f'    <neighbor index="{neighbor["cluster_index"]}"><keywords>{html.escape(", ".join(neighbor["keywords"]), quote=True)}</keywords></neighbor>'
        for neighbor in sample.get("neighbors", [])
    )
    retry_note = f"    - This is retry {attempt}. The previous answer failed validation; choose a different valid label.\n" if attempt > 1 else ""
    used_block = f"\nAlready used labels. Do not reuse any of these:\n<used_labels>\n{used_xml}\n</used_labels>\n" if used_xml else ""
    rejected_block = f"\nRejected labels from previous attempts. Do not reuse these:\n<rejected_labels>\n{rejected_xml}\n</rejected_labels>\n" if rejected_xml else ""
    neighbors_block = (
        "\nNearest neighboring clusters. Use these to make this label contrastive rather than generic:\n"
        f"<neighbor_clusters>\n{neighbors_xml}\n</neighbor_clusters>\n"
        if neighbors_xml
        else ""
    )
    return f"""You are naming one knowledge mountain in a cognition map.
The model is small, so keep reasoning private and output format strict.

Return only strict JSON with keys: primaryLabel, subtitle, keywordChips.
Rules:
- Prefer a polished Chinese label of 2 to 6 characters.
- If English is clearly better, use 1 to 3 words.
- primaryLabel must be specific and contrast this cluster from neighboring clusters.
- subtitle should be a concise phrase explaining the cluster focus.
- keywordChips must contain exactly 3 short keywords.
- Avoid generic labels like 职场智慧 unless no sharper label is possible.
- Use neutral written style. Avoid slang, sentence fragments, and invented abbreviations.
- Do not output reasoning, filenames, URLs, code syntax, XML tags, or explanations outside the JSON object.
- Do not output special tokens such as <|endoftext|>, <think>, or </think>.
- Do not use the words Cluster, Mountain, Label, or Note.
- Avoid generic or broken labels like win, key, need, road, attentio, greatapi.
{retry_note}
Good style examples:
关系沟通
明智决策
科学思维
精英思维
银行金融
Self Regulation

Bad style examples:
干啥不顺
招聘和几
智信
活企
活下去
建立自己
如何坚持
永远是企
问题库
死胡同
过程性解
避免陷入
联系到
win
key
summary every time
elaborate usability tests
{used_block}{rejected_block}{neighbors_block}
<cluster index="{sample["cluster_index"]}">
  <keywords>{html.escape(", ".join(sample["keywords"]), quote=True)}</keywords>
  <notes>
{notes_xml}
  </notes>
</cluster>
"""
