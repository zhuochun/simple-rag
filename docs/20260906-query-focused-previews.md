# Query-focused CLI previews

Status: revised specification. Includes always-on query-first previews and the
concise text-renderer repair. No implementation changes are part of this document.

## Outcome

Let CLI users see a query-matching part of a retrieved chunk without adding
knowledge-base-specific semantics to simple-rag.

Current code shortens each matched chunk from its beginning. The CLI already
offers `--brief-chars` and `--full`; the web search page displays the full anchor
chunk. This proposal changes only concise CLI presentation.

## Proposed behavior

Concise output always prefers a query-matching paragraph, falling back to the
existing beginning-of-chunk preview. No new option or configuration setting.

- Select a paragraph from each already-retrieved matched chunk using
  the original user query. Keep the same file order, matched-chunk order, scores,
  locator fields, and JSON/JSONL output structure; preview strings intentionally
  change when a suitable paragraph is found.
- `--full`: keep complete chunk text and existing metadata unchanged.
- `--brief-chars`: retain the existing default and validation behavior.

Use a small deterministic selector, with no model call or corpus statistics:

1. Split the stored chunk at blank lines into paragraphs.
2. Split the query into runs of Unicode letters/numbers, lowercase and deduplicate
   them. Count distinct query terms occurring as complete terms in each paragraph
   using the same tokenization. No stemming, stop-word list or language inference.
3. Pick the paragraph with the most matches; break ties by earliest position.
4. If it has no matches, or cannot fit in `--brief-chars` after whitespace
   normalization and omission markers, use the existing start preview.
   Do not search for a lower-scoring paragraph that fits.
5. Otherwise return that whole paragraph, with `...` before/after it when
   preceding/following nonblank chunk content was omitted. Do not concatenate
   separate passages or cut the chosen paragraph to make it fit.

This is literal matching, not a relevance or evidence-quality judgment.
Queries without useful lexical matches, including unsupported tokenization
cases, simply retain the existing preview. A complete paragraph can still depend
on surrounding context; do not present the excerpt as an answer or claim that
all qualifications are included. Users can inspect the note or rerun with `--full`.

## Example

Illustrative chunk, with a paragraph break between these two passages:

> This guide describes backup configuration and recovery procedures.
>
> Backups are retained for 30 days. Deleted backups cannot be recovered.

For `run-query --brief-chars 90 "backups retained"`:

```text
Before: This guide describes backup configuration and recovery procedures. Backups are retained...
After:  ...Backups are retained for 30 days. Deleted backups cannot be recovered.
```

The existing `matched_chunks` string array carries this text. No new result fields.

## Output formats

JSON and JSONL retain their existing structures. Concise text output displays the
same `matched_chunks` strings, in order, beneath each result's existing file
locator and score. Use the available `path` and `file` fields; do not invent a
chunk identifier absent from concise results.

The text renderer currently reads
`text` and `chunk` fields that concise results do not contain, leaving previews
blank. Make it consume the existing concise fields. Full text output is unchanged.

## Acceptance

- **CHG-preview-choice:** Default concise output can expose a matching later
  paragraph; ties select the earlier paragraph and unmatched/oversized selections
  fall back to the existing start behavior.
- **CHG-preview-integrity:** A selected paragraph retains its complete text except
  whitespace normalization; omission markers are included in its character budget.
  Existing start-preview behavior, including very small budgets, stays compatible.
- **CHG-preview-compatibility:** Full output and JSON/JSONL structures stay
  unchanged. Default concise preview strings may change. Server-backed and local
  CLI retrieval use the same selection behavior; ranking and query traces retain
  the original full retrieval payload.
- **CHG-preview-formats:** JSON, JSONL and text expose the same selected strings
  in matched-chunk order. Concise text also identifies the actual file and score,
  without reading fields absent from the concise result.
- **CHG-preview-generic:** No collection names, heading names, document roles or
  corpus-specific rules participate in selection.

## Scope

Shared preview formatting, the concise text-renderer repair, CLI help,
and concise-output documentation.
No reader/index/schema changes, re-embedding, ranking changes, role labels,
provenance extraction, new endpoints, web UI redesign, or evidence-only mode.
No additional dependencies, provider requests, configuration files or query logs.

The selector's usefulness remains unverified; the earlier lexical-window
prototype did not establish the quality of this whole-paragraph rule. Check
representative matching, fallback and context examples before shipping. Do not
claim the presentation change improves retrieval accuracy.
