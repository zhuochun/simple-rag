from __future__ import annotations

from pathlib import Path
import re


DEFAULT_MAX_TOKENS = 1000
DEFAULT_MIN_TOKENS = 10
TOKEN_RE = re.compile(r"[\u4e00-\u9fff]|[^\W_]+|[^\s]", re.UNICODE)


def count_tokens(text: str | None) -> int:
    if not text:
        return 0
    return len(TOKEN_RE.findall(text))


def split_chunk_by_tokens(text: str, max_tokens: int = DEFAULT_MAX_TOKENS) -> list[str]:
    if not text:
        return []
    if count_tokens(text) <= max_tokens:
        return [text]

    parts: list[str] = []
    current: list[str] = []
    current_tokens = 0
    for para in re.split(r"\n{2,}", text):
        para_tokens = count_tokens(para)
        if para_tokens > max_tokens:
            if current:
                parts.append("\n\n".join(current))
                current = []
                current_tokens = 0
            parts.extend(split_large_block_by_lines(para, max_tokens))
            continue

        gap = 0 if not current else 1
        if current_tokens + para_tokens + gap > max_tokens:
            parts.append("\n\n".join(current))
            current = [para]
            current_tokens = para_tokens
        else:
            current.append(para)
            current_tokens += para_tokens
    if current:
        parts.append("\n\n".join(current))
    return parts


def split_large_block_by_lines(text: str, max_tokens: int) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    current_tokens = 0
    for line in text.split("\n"):
        line_tokens = count_tokens(line)
        if line_tokens > max_tokens:
            if current:
                parts.append("\n".join(current))
                current = []
                current_tokens = 0
            parts.extend(split_hard_by_chars(line, max_tokens))
            continue

        gap = 0 if not current else 1
        if current_tokens + line_tokens + gap > max_tokens:
            parts.append("\n".join(current))
            current = [line]
            current_tokens = line_tokens
        else:
            current.append(line)
            current_tokens += line_tokens
    if current:
        parts.append("\n".join(current))
    return parts


def split_hard_by_chars(text: str, max_tokens: int) -> list[str]:
    pieces = re.findall(r"(?:[\u4e00-\u9fff]|[^\W_]+|[^\s])\s*", text, re.UNICODE | re.DOTALL)
    if not pieces:
        return [text[i : i + max_tokens] for i in range(0, len(text), max_tokens)]

    parts: list[str] = []
    current: list[str] = []
    current_tokens = 0
    for piece in pieces:
        piece_tokens = count_tokens(piece)
        if current and current_tokens + piece_tokens > max_tokens:
            parts.append("".join(current))
            current = []
            current_tokens = 0
        current.append(piece)
        current_tokens += piece_tokens
    if current:
        parts.append("".join(current))
    return parts


def filter_small_chunks(chunks: list[str], min_tokens: int = DEFAULT_MIN_TOKENS) -> list[str]:
    return [chunk for chunk in chunks if count_tokens(chunk) >= min_tokens]


class BaseReader:
    max_words = 1000
    min_words = 10

    def __init__(self, file: str):
        self.file = file
        self.loaded = False
        self.chunks: list[str] = []

    def load(self) -> "BaseReader":
        raise NotImplementedError

    def get_chunk(self, idx: int | None) -> str | None:
        if not self.chunks:
            return None
        index = idx or 0
        if index >= len(self.chunks) or index < -len(self.chunks):
            return None
        return self.chunks[index]


class TextReader(BaseReader):
    def load(self) -> "TextReader":
        if self.loaded:
            return self
        path = Path(self.file)
        if not path.exists():
            self.loaded = True
            return self

        try:
            lines: list[str] = []
            boundary = 0
            words = 0
            in_frontmatter = False
            with path.open("r", encoding="utf-8", errors="replace", newline="") as fh:
                for idx, line in enumerate(fh):
                    stripped = line.strip()
                    if in_frontmatter:
                        if stripped in ("---", "..."):
                            in_frontmatter = False
                        continue
                    if idx == 0 and stripped == "---":
                        in_frontmatter = True
                        continue
                    if (line.startswith("- ") and ":" in line) or line.startswith("  - [["):
                        continue
                    if line.startswith("<"):
                        continue
                    if stripped == "---":
                        boundary = len(lines)
                        continue

                    lines.append(line)
                    words += count_tokens(stripped)
                    if stripped == "":
                        boundary = len(lines)
                    if words >= self.max_words:
                        split_at = len(lines) if boundary == 0 else boundary
                        self.chunks.append("".join(lines[:split_at]))
                        lines = lines[split_at:]
                        words = sum(count_tokens(line.strip()) for line in lines)
                        boundary = 0
            if lines:
                self.chunks.append("".join(lines))
        except FileNotFoundError:
            pass

        self.chunks = filter_small_chunks(self.chunks, self.min_words)
        self.loaded = True
        return self


class NoteReader(BaseReader):
    header_re = re.compile(r"^## (.+?)$")
    link_re = re.compile(r"^- \[([ xX])\] ")

    def load(self) -> "NoteReader":
        if self.loaded:
            return self
        path = Path(self.file)
        if not path.exists():
            self.loaded = True
            return self

        notes: list[tuple[list[str], bool]] = []
        note_body: list[str] | None = None
        done = False
        try:
            with path.open("r", encoding="utf-8", errors="replace") as fh:
                for raw_line in fh:
                    line = raw_line.rstrip("\r\n")
                    if self.header_re.match(line):
                        if note_body is not None:
                            notes.append((note_body, done))
                        note_body = [line]
                        done = False
                    elif note_body is not None:
                        match = self.link_re.match(line)
                        if match:
                            done = match.group(1) != " "
                        elif line.strip():
                            note_body.append(line)
            if note_body is not None:
                notes.append((note_body, done))
        except FileNotFoundError:
            self.loaded = True
            return self

        for body, is_done in notes:
            if not is_done:
                continue
            self.chunks.extend(split_chunk_by_tokens("\n".join(body), self.max_words))
        self.chunks = filter_small_chunks(self.chunks, self.min_words)
        self.loaded = True
        return self


class JournalReader(BaseReader):
    skip_headings = ("精力", "感恩")

    def load(self) -> "JournalReader":
        if self.loaded:
            return self
        path = Path(self.file)
        if not path.exists():
            self.loaded = True
            return self

        try:
            self._parse_journal(path)
        except FileNotFoundError:
            pass
        self.loaded = True
        return self

    def _parse_journal(self, path: Path) -> None:
        started = False
        heading = ""
        lines: list[str] = []
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for raw_line in fh:
                line = raw_line.rstrip("\r\n")
                if not line.strip():
                    continue
                if not started:
                    if not line.startswith("## "):
                        continue
                    started = True
                    heading = line[3:].strip()
                    lines = [self._clean_line(line)]
                    continue
                if line.startswith("## "):
                    self._push_chunk(heading, lines)
                    heading = line[3:].strip()
                    lines = [self._clean_line(line)]
                    continue
                if line.lstrip().startswith("<"):
                    continue
                lines.append(self._clean_line(line))
        if started:
            self._push_chunk(heading, lines)

    def _push_chunk(self, heading: str, lines: list[str]) -> None:
        if any(skip in heading for skip in self.skip_headings):
            return
        if len(lines) < 3:
            return
        self.chunks.extend(split_chunk_by_tokens("\n".join(lines), self.max_words))
        self.chunks = filter_small_chunks(self.chunks, self.min_words)

    @staticmethod
    def _clean_line(line: str) -> str:
        return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1", line)


def get_reader(name: str | None) -> type[BaseReader] | None:
    match str(name or "").lower():
        case "text":
            return TextReader
        case "note":
            return NoteReader
        case "journal":
            return JournalReader
        case _:
            return None
