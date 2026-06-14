# Replace Retrieval Logic with Weighted RRF + Query Plan Fusion

## 1. Goal

Replace the existing retrieval logic with a new unified retrieval pipeline for both `q` and `q_plus`.

The new pipeline should improve retrieval quality without adding a reranker. It should rely on:

* query planning;
* parallel vector and BM25 retrieval;
* weighted Reciprocal Rank Fusion;
* deterministic boosts to protect exact/original-query matches;
* chunk-level fusion followed by file-level aggregation.

`exe/run-query` is the CLI frontend for `q`. It must call the same
`Retriever#retrieve_q` implementation as the HTTP `/q` endpoint and return the
same ranked files. CLI formatting may differ after retrieval, but the CLI must
not maintain separate retrieval logic.

Backward compatibility is not required. Existing retrieval APIs, modes, helper functions, and response shapes may be changed as needed.

## 2. Non-goals

Do not add an LLM reranker.

Do not depend on external reranking models.

Do not optimize for compatibility with the old `embedding`, `bm25`, and `hybrid` modes if they make the new model harder to implement.

Do not let query expansion dominate original-query results.

Do not merge chunks by file before fusion. Fusion must happen at chunk level first.

## 3. High-level behavior

There are two retrieval entry points:

### `q`

`q` is deterministic, fast, and original-query focused.

It should use:

* original query only;
* vector search on original query;
* one BM25 phrase search on the original query when the query has 5 tokens or fewer;
* BM25 token search and BM25 phrase search on the original query when the query has more than 5 tokens;
* weighted RRF fusion;
* deterministic boosts;
* chunk-level fusion;
* file-level aggregation.

### `q_plus`

`q_plus` is recall-enhanced.

It should use:

* original query;
* one semantic rewrite;
* keyword variants;
* vector search on original query;
* one BM25 phrase search on the original query when the query has 5 tokens or fewer;
* BM25 token search and BM25 phrase search on the original query when the query has more than 5 tokens;
* vector search on semantic rewrite;
* BM25 phrase search on keyword variants;
* weighted RRF fusion;
* deterministic boosts and penalties;
* chunk-level fusion;
* file-level aggregation.

## 4. Query planning

Introduce a query plan object.

Example structure:

```ruby
QueryPlan = Struct.new(
  :original_query,
  :semantic_rewrite,
  :keyword_variants,
  :lists,
  keyword_init: true
)
```

### For `q`

```ruby
{
  original_query: query,
  semantic_rewrite: nil,
  keyword_variants: [],
  lists: [
    {
      name: "vec:original",
      backend: "vector",
      query_type: "original",
      query: query,
      weight: 1.2
    },
    {
      name: "bm25:phrase",
      backend: "bm25",
      query_type: "original",
      query: query,
      phrase: true,
      weight: 1.2
    }
  ]
}
```

### For `q_plus`

```ruby
{
  original_query: query,
  semantic_rewrite: semantic_rewrite,
  keyword_variants: keyword_variants,
  lists: [
    {
      name: "vec:original",
      backend: "vector",
      query_type: "original",
      query: query,
      weight: 1.2
    },
    {
      name: "bm25:phrase",
      backend: "bm25",
      query_type: "original",
      query: query,
      phrase: true,
      weight: 1.2
    },
    {
      name: "vec:expanded",
      backend: "vector",
      query_type: "expanded",
      query: semantic_rewrite,
      weight: 0.7
    },
    {
      name: "bm25:variants",
      backend: "bm25",
      query_type: "expanded",
      query: keyword_variants,
      phrase: true,
      weight: 0.6
    }
  ]
}
```

The examples above show plans for original queries with 5 tokens or fewer.
For longer original queries, add:

```ruby
{
  name: "bm25:original",
  backend: "bm25",
  query_type: "original",
  query: query,
  weight: 1.1
}
```

## 5. Query expansion rules

### Semantic rewrite

Only `q_plus` should create a semantic rewrite.

Generate exactly one rewrite.

The rewrite should preserve the original intent but improve semantic recall.

Prompt requirements:

* keep the same user intent;
* do not broaden the question;
* do not add new concepts not implied by the original query;
* output one rewritten query only;
* no bullets, no explanations.

Example prompt:

```text
Rewrite the user query into one concise semantic search query.

Rules:
- Preserve the exact intent.
- Do not broaden the scope.
- Do not add assumptions.
- Prefer terms likely to appear in notes.
- Output one query only.
```

### Keyword variants

Only `q_plus` should use keyword variants.

Reuse the existing keyword-variant idea:

* short terms;
* aliases;
* acronyms;
* bilingual Chinese/English terms when useful;
* optimized for BM25 / FTS exact matching.

Keyword variants are only used for BM25. They should not be used for vector search.

Normalize generated queries before execution by trimming whitespace,
collapsing repeated whitespace, and comparing case-insensitively.

Do not execute duplicate retrieval lists:

* if the semantic rewrite normalizes to the original query, omit `vec:expanded`;
* remove keyword variants that normalize to the original query, the semantic rewrite, or another variant;
* collapse any remaining lists with the same backend, configured lookup, physical index, normalized query, and phrase setting;
* use only the retained physical source lists when calculating RRF, source summaries, and diversity boosts.

Do not collapse distinct configured lookups, even when they point at the same
physical SQLite table. Lookup identity is part of result identity.

For original queries with 5 tokens or fewer, execute only `bm25:phrase`. Do not
also execute `bm25:original`. For original queries with more than 5 tokens,
execute both lists.

Count original-query tokens with the same lexical extraction used by
`bm25:original`:

```ruby
query.scan(/[\p{L}\p{N}_]+/u)
```

This keeps short-query planning deterministic for punctuation and CJK input.

If `q_plus` expansion fails, produces an empty semantic rewrite, produces no
usable keyword variants, or leaves no usable expanded lists after
deduplication, fall back to the `q` plan. Return fallback metadata so clients
can explain the effective behavior.

## 6. Retrieval execution

Each query plan list should produce a ranked list of chunk candidates.

A chunk candidate identity is:

```ruby
[lookup, path, chunk]
```

`path` is not globally unique: two configured lookups may contain the same
relative path. Use `[lookup, path, chunk]` for chunk-fusion keys and
`[lookup, path]` for file-aggregation keys. A canonical physical-index
identifier may be stored separately for source-list deduplication, but it must
not collapse results from distinct configured lookups.

Each candidate should include:

```ruby
{
  "path" => path,
  "chunk" => chunk,
  "text" => text,
  "lookup" => lookup_name,
  "score" => raw_backend_score,
  "_source_list" => list_name,
  "_backend" => "vector" | "bm25",
  "_query_type" => "original" | "expanded",
  "_rank" => rank_in_source_list,
  "_weight" => list_weight
}
```

Vector retrieval and BM25 retrieval should run independently. They may run in
parallel where the retrieval infrastructure supports it safely.

### SQLite connection ownership

Do not execute concurrent queries through the same `SqliteIndex` instance or
underlying SQLite connection.

The current store cache is keyed by physical SQLite table and returns one
shared store instance. Do not reuse that cache unchanged for concurrent
query-plan lists.

Use one of these safe strategies:

* open a separate read connection per concurrently executing list / worker; or
* serialize access per physical SQLite table when reusing a cached connection.

Use one bounded retrieval worker pool across list execution and lookup
execution. Do not create nested pools that multiply the configured concurrency.

```ruby
RETRIEVAL_THREADS_MAX = 8
```

BM25 ranks and raw scores are local to one SQLite FTS table. Each logical BM25
list must therefore be expanded into one physical source list per configured
lookup / SQLite FTS rank domain before fusion. For example:

```text
bm25:phrase:notes
bm25:phrase:talks
bm25:variants:notes
bm25:variants:talks
```

Do not merge BM25 results from different SQLite tables into one ranked source
list. Vector results may be globally ranked across selected lookups because
this project requires consistent vector dimensions and uses the same distance
metric across indexes.

Within each BM25 physical source list, sort by raw BM25 score descending, then
lookup, path, and chunk as deterministic tie-breakers before assigning ranks.

For each vector source list:

1. retrieve up to `vector_candidate_depth` chunks from each selected lookup;
2. apply the configured per-lookup vector threshold;
3. merge candidates from all selected lookups;
4. sort globally by vector score descending, then lookup, path, and chunk as deterministic tie-breakers;
5. keep the top `vector_candidate_depth` merged candidates;
6. assign source-list ranks after the global trim.

Do not assign vector RRF ranks independently per lookup.

### Retrieval failure policy

Backend retrieval failures are not query-expansion failures:

* if vector or BM25 execution fails for `q`, fail the request;
* if vector or BM25 execution fails for `q_plus`, fail the request;
* only semantic-rewrite and keyword-variant generation failures trigger the
  `q_plus` to `q` fallback.

Do not silently return a BM25-only or vector-only result set when a planned
backend failed.

Retrieve more chunks than the requested file count so aggregation has enough
evidence:

```ruby
vector_candidate_depth = clamp(top_n * 6, min: 64, max: 512)
bm25_candidate_depth = clamp(top_n * 10, min: 100, max: 800)
```

### Shared input validation

Validate public retrieval inputs inside `Retriever` so HTTP and CLI behavior
cannot diverge:

* reject empty or whitespace-only queries;
* reject `top_n <= 0`;
* reject `top_n > MAX_TOP_N`;
* reject an empty resolved lookup list.

Use:

```ruby
MAX_TOP_N = 100
```

HTTP `/q` and `/q_plus` should return `400` JSON errors for invalid retrieval
inputs. `run-query` should print an actionable error and exit nonzero.

Apply equivalent validation to `/similar`: reject an empty `note`, invalid
`topN`, and an empty resolved lookup list with a `400` JSON error.

### Configuration validation

Lookup-aware identity depends on stable configured lookup names. During config
loading:

* reject missing or whitespace-only lookup names;
* reject duplicate lookup names;
* do not silently overwrite entries in `path_map`.

### Provider lifecycle

`q` requires embeddings but does not require chat. Server startup and
`run-query` should validate and initialize only the embedding-provider
requirements needed by `q`.

Defer chat-provider credential validation and service-readiness checks to
chat-dependent operations such as `q_plus` expansion, discussion, and article
analysis. Catch expansion failures inside `retrieve_q_plus` and fall back to
the `q` plan so chat-provider failures do not disable deterministic retrieval.

## 7. Fusion

Fusion must happen at chunk level.

Do not aggregate by file before fusion.

### Formula

For each chunk candidate:

```text
final_score =
  0.75 * normalized_rrf
+ 0.15 * normalized_score_signal
+ deterministic_boosts
```

Clamp final score to `[0.0, 1.0]`.

```ruby
final_score = [[final_score, 0.0].max, 1.0].min
```

### Weighted RRF

For each source list:

```text
rrf_contribution = list_weight * (1.0 / (rrf_k + rank))
```

Use:

```ruby
rrf_k = 60
```

For each unique chunk `[lookup, path, chunk]`, sum all RRF contributions across source lists.

Normalize RRF by dividing each chunk’s RRF score by the maximum RRF score among all candidates.

```ruby
normalized_rrf = chunk_rrf_score / max_rrf_score
```

If `max_rrf_score <= 0`, use `0.0`.

### Normalized score signal

Backend raw scores are not directly comparable, so this signal must stay weak.

For each source list, min-max normalize raw scores within that list:

```ruby
normalized_score =
  if max_score > min_score
    (score - min_score) / (max_score - min_score)
  elsif score > 0
    1.0
  else
    0.0
  end
```

For each chunk, sum:

```text
score_signal += list_weight * normalized_score
```

Normalize again by the maximum score signal across all chunks:

```ruby
normalized_score_signal = score_signal / max_score_signal
```

If `max_score_signal <= 0`, use `0.0`.

## 8. Deterministic boosts and penalties

Apply boosts after RRF and score signal.

Boosts should be small and bounded.

### Top-rank original-query protection

Apply only when the result came from an original-query source list.

```text
+0.05 if the chunk ranks #1 in any original-query source list
+0.02 if the chunk ranks #2 or #3 in any original-query source list
```

If both conditions apply, use only the highest one.

### Expanded-only penalty

For `q_plus`:

```text
-0.05 if the chunk appears only in expanded-query lists and never appears in original-query lists
```

This prevents semantic rewrite / keyword variants from overpowering exact original-query matches.

### Multi-chunk same-file evidence boost

Do not apply this at chunk fusion stage.

Apply it at file aggregation stage.

Rule:

```text
+0.02 file-level boost if:
  the same file has at least 2 strong matched chunks;
  and at least one matched chunk came from an original-query list;
```

Cap this boost at `+0.02`.

Do not give more boost for very long files with many weak matches.

## 9. File-level aggregation

After chunk-level fusion, aggregate chunks into files.

Group chunks by `[lookup, path]`.

Each file result should include:

```ruby
{
  path: path,
  id: id,
  lookup: lookup,
  url: url,
  score: file_score,
  anchor_chunk: best_chunk,
  matched_chunks: matched_chunks,
  source_summary: source_summary,
  debug: debug_info
}
```

### Anchor chunk

The anchor chunk is the highest-scoring fused chunk for the file. Break equal
scores by chunk number ascending.

```ruby
anchor_chunk = chunks_for_file.sort_by { |c| [-c["final_score"], c["chunk"]] }.first
```

### Retained and strong matched chunks

Retain chunks for display when they pass either condition:

```text
chunk is in the top global fused candidates
OR chunk final_score >= strong_chunk_threshold
```

Define strong chunks for file-level boosts more narrowly:

```text
chunk final_score >= strong_chunk_threshold
```

The top-global rule is only for retaining useful display evidence. A weak chunk
must not become strong merely because it appears in the top-global set.

Initial value:

```ruby
strong_chunk_threshold = 0.35
```

The top-global cutoff is:

```ruby
top_global_strong_chunks = clamp(top_n * 3, min: 30, max: 100)
```

Keep at most:

```ruby
max_chunks_per_file = 3
```

The anchor chunk must always be included. Select the remaining retained chunks
by final score descending, then chunk number ascending.

Calculate file-level boosts from strong chunks within the retained
`matched_chunks` only. This keeps scoring evidence bounded by
`MAX_CHUNKS_PER_FILE` and makes every file boost explainable from returned
chunks.

### File score

Use anchor score as dominant signal.

```text
file_score =
  anchor_chunk.final_score
+ evidence_boost
+ source_list_diversity_boost
```

Where:

```text
evidence_boost = 0.02 if multi-chunk evidence rule passes, else 0.0
source_list_diversity_boost = min(number_of_distinct_source_lists - 1, 2) * 0.01
```

Cap `source_list_diversity_boost` at `+0.02`.

This is intentionally a source-list diversity boost, not a backend diversity
boost. Count only retained physical source lists represented by the file's
strong matched chunks after deduplication. Multiple hits from the same physical
source list do not increase the boost. Weak retained chunks do not add
diversity.

Clamp final file score to `[0.0, 1.0]`.

### Sorting

Sort files by:

1. `file_score` descending;
2. anchor chunk score descending;
3. number of original-query matches descending;
4. lookup ascending, then path ascending as deterministic tie-breakers.

## 10. Output model

Return top N files, not top N raw chunks.

Each file should expose enough information for UI rendering and retrieval debugging.

Suggested JSON output:

```json
{
  "query": "original user query",
  "requested_mode": "q_plus",
  "mode": "q_plus",
  "fallback": null,
  "semantic_rewrite": "rewritten semantic query",
  "keyword_variants": ["variant one", "variant two"],
  "count": 10,
  "data": [
    {
      "path": "...",
      "id": "...",
      "url": "...",
      "lookup": "...",
      "score": 0.83,
      "anchor_chunk": {
        "chunk": 3,
        "score": 0.83,
        "text": "..."
      },
      "matched_chunks": [
        {
          "chunk": 3,
          "score": 0.83,
          "text": "...",
          "sources": ["vec:original", "bm25:phrase:notes"],
          "evidence": [
            {
              "source_list": "vec:original",
              "backend": "vector",
              "query_type": "original",
              "rank": 2,
              "raw_score": 0.91,
              "normalized_score": 0.88,
              "rrf_contribution": 0.01935
            },
            {
              "source_list": "bm25:phrase:notes",
              "backend": "bm25",
              "query_type": "original",
              "rank": 1,
              "raw_score": 8.4,
              "normalized_score": 1.0,
              "rrf_contribution": 0.01967
            }
          ]
        },
        {
          "chunk": 4,
          "score": 0.52,
          "text": "...",
          "sources": ["bm25:original:notes"],
          "evidence": [
            {
              "source_list": "bm25:original:notes",
              "backend": "bm25",
              "query_type": "original",
              "rank": 4,
              "raw_score": 4.1,
              "normalized_score": 0.61,
              "rrf_contribution": 0.01719
            }
          ]
        }
      ],
      "source_summary": {
        "source_lists": ["vec:original", "bm25:phrase:notes", "bm25:original:notes"],
        "has_original_match": true,
        "has_expanded_match": false,
        "original_match_count": 2,
        "expanded_match_count": 0
      },
      "debug": {
        "anchor_rrf": 0.91,
        "anchor_score_signal": 0.77,
        "anchor_boosts": {
          "top_rank_original": 0.05,
          "expanded_only_penalty": 0.0
        },
        "file_boosts": {
          "multi_chunk_evidence": 0.02,
          "source_list_diversity": 0.02
        }
      }
    }
  ]
}
```

Build `source_summary` from the retained `matched_chunks`:

* `source_lists` contains distinct retained physical source-list names;
* `original_match_count` counts matched chunks with at least one original-query evidence record;
* `expanded_match_count` counts matched chunks with at least one expanded-query evidence record.

For concise output, omit `debug` and trim chunk text.

For full output, include debug metadata.

When `q_plus` falls back to `q`, return:

```json
{
  "requested_mode": "q_plus",
  "mode": "q",
  "fallback": {
    "reason": "expansion_failed"
  },
  "semantic_rewrite": null,
  "keyword_variants": []
}
```

Keep `semantic_rewrite` and `keyword_variants` in the output for UI
explainability. When fallback happens after partial expansion, return any
successfully generated metadata that was available before fallback.

For `q.html`, file cards should map their displayed note text and chunk number
from `anchor_chunk.text` and `anchor_chunk.chunk`. Keep `id` at file-result
level for labels and links.

Do not route graph search through `/q` or `/q_plus`. `graph.html` should use
`/similar` only, for both initial text search and node expansion, and should
continue consuming the existing chunk-shaped `/similar` response. Remove the
graph Search+ action and expansion-detail UI. No mixed-shape graph normalizer
is needed. Initial graph search should send the existing `/similar` request
shape:

```json
{
  "note": "search text",
  "paths": ["..."],
  "topN": 20
}
```

## 11. Suggested code organization

Replace the existing retrieval logic with these components.

### `QueryPlanner`

Responsible for building query plans.

Methods:

```ruby
build_q_plan(query)
build_q_plus_plan(query)
semantic_rewrite(query)
keyword_variants(query)
```

### `RetrievalExecutor`

Responsible for executing query plan lists.

Methods:

```ruby
execute_plan(plan, lookup_paths, top_n:)
execute_list(list, lookup_paths, top_n:)
```

### `FusionEngine`

Responsible for chunk-level weighted RRF and deterministic boosts.

Methods:

```ruby
fuse_chunk_candidates(candidates_by_list, rrf_k: 60)
apply_chunk_boosts(fused_chunks)
```

### `FileAggregator`

Responsible for turning fused chunks into top file results.

Methods:

```ruby
aggregate_files(fused_chunks, top_n:)
file_score(chunks_for_file)
```

### `Retriever`

Public entry point.

Methods:

```ruby
retrieve_q(lookup_paths, query, top_n:)
retrieve_q_plus(lookup_paths, query, top_n:)
```

## 12. Candidate constants

Use these initial constants:

```ruby
RRF_K = 60
MAX_TOP_N = 100
RETRIEVAL_THREADS_MAX = 8

FINAL_SCORE_WEIGHTS = {
  rrf: 0.75,
  score_signal: 0.15
}

LIST_WEIGHTS_Q = {
  "vec:original" => 1.2,
  "bm25:original" => 1.1,
  "bm25:phrase" => 1.2
}

LIST_WEIGHTS_Q_PLUS = {
  "vec:original" => 1.2,
  "bm25:original" => 1.1,
  "bm25:phrase" => 1.2,
  "vec:expanded" => 0.7,
  "bm25:variants" => 0.6
}

ORIGINAL_QUERY_PHRASE_MAX_TOKENS = 5

VECTOR_CANDIDATE_DEPTH = {
  multiplier: 6,
  min: 64,
  max: 512
}

BM25_CANDIDATE_DEPTH = {
  multiplier: 10,
  min: 100,
  max: 800
}

TOP_GLOBAL_STRONG_CHUNKS = {
  multiplier: 3,
  min: 30,
  max: 100
}

BOOSTS = {
  original_rank_1: 0.05,
  original_rank_2_or_3: 0.02,
  expanded_only_penalty: -0.05,
  multi_chunk_evidence: 0.02,
  source_list_diversity_per_extra_list: 0.01,
  source_list_diversity_cap: 0.02
}

STRONG_CHUNK_THRESHOLD = 0.35
MAX_CHUNKS_PER_FILE = 3
```

## 13. CLI / UI behavior

Remove the CLI mode argument. `run-query` is always the CLI frontend for `q`.

```bash
run-query "query"
```

`q_plus` remains available through the HTTP endpoint and UI Search+ action.

UI mapping:

```text
q.html Search    -> q
q.html Search+   -> q_plus
graph.html Search -> similar
graph.html Expand -> similar
```

Remove the Synthesize UI action and `/synthesize` endpoint.

Keep `/similar` and `/random` on their existing chunk-shaped
retrieval behavior. They are not migrated to file-level aggregation in this
rewrite.

Update `README.md` to remove the Synthesize action and legacy `run-query`
retrieval modes. Remove unused synthesis requires from `exe/run-server` and
`lib/simple_rag.rb`. Delete `server/synthesizer.rb` if no remaining callers
need it.

## 14. Acceptance criteria

### Functional

`q` must work without any LLM query expansion.

`q_plus` must produce one semantic rewrite and keyword variants, or explicitly fall back to `q`.

Both `q` and `q_plus` must search vector and BM25 backends.

`exe/run-query` must call the same `retrieve_q` implementation as HTTP `/q`.

Fusion must happen at chunk level before file aggregation.

Final output must return top N files with anchor chunk and matched chunks.

`q`, `/similar`, and `run-query` must work when chat-provider credentials are
missing but embedding-provider requirements are satisfied.

`graph.html` must use `/similar` only and continue consuming chunk-shaped
similarity results.

Invalid queries, limits, and lookup configurations must fail fast with
actionable errors.

Expanded-only results must be penalized.

Original-query top hits must be protected.

### Quality

Exact phrase matches should not disappear because of semantic expansion.

A file with multiple strong relevant chunks should rank above a file with one marginal match.

Long generic files should not win merely because they have many weak matches.

`q` should be faster and more deterministic than `q_plus`.

`q_plus` should improve recall without overwhelming original-query precision.

### Debuggability

Full output should include:

* source lists per chunk;
* per-source-list rank, raw score, normalized score, and RRF contribution;
* normalized score signal;
* deterministic boosts;
* file-level boosts.

This is important for tuning weights later.

## 15. Test cases

Create retrieval tests with a small synthetic SQLite index.

### Test 1: Original exact match protection

Given:

* one chunk ranks #1 in `bm25:phrase`;
* another chunk ranks high in `vec:expanded`;

Expected:

* original phrase match ranks higher.

### Test 2: Expanded-only penalty

Given:

* a chunk appears only in `vec:expanded`;
* another chunk appears in `bm25:original`;

Expected:

* expanded-only chunk receives `-0.05` penalty.

### Test 3: Chunk-level fusion before file aggregation

Given:

* same file has two relevant chunks;
* another file has one high-scoring chunk;

Expected:

* chunks are first scored independently;
* then file-level score uses anchor score plus capped evidence boost.

### Test 4: Multi-chunk evidence cap

Given:

* a long file has ten weak matches;
* a short file has two strong original-query matches;

Expected:

* long file does not win purely by match count;
* weak top-global retained chunks do not contribute file-level evidence or source-list diversity boosts.

### Test 5: `q` does not call LLM expansion

Expected:

* `q` executes without calling semantic rewrite or keyword variant generation.

### Test 6: `q_plus` uses exactly one semantic rewrite

Expected:

* one semantic rewrite is generated;
* vector search is run for original and rewritten queries;
* keyword variants are used only for BM25 phrase matching;
* output includes `semantic_rewrite` and `keyword_variants`.

### Test 7: Lookup-aware chunk identity

Given:

* two configured lookups contain the same relative path and chunk number.

Expected:

* the chunks remain separate through fusion and file aggregation.

### Test 8: BM25 rank domains remain separate

Given:

* two SQLite FTS tables return BM25 results with different raw score ranges.

Expected:

* each table is fused as a separate physical source list.

### Test 9: Short-query and expansion deduplication

Given:

* an original query has 5 tokens or fewer;
* punctuation and CJK queries are included;
* a semantic rewrite or keyword variant normalizes to an already executed query.

Expected:

* only `bm25:phrase` is executed for the original query;
* token counting uses the documented lexical extraction;
* duplicate expanded lists are omitted;
* omitted lists do not contribute RRF or diversity boosts.

### Test 10: `run-query` uses `q`

Expected:

* `run-query "query"` calls the same `retrieve_q` implementation as HTTP `/q`;
* the CLI does not expose a retrieval mode argument.

### Test 11: `q_plus` fallback

Given:

* semantic rewrite or keyword-variant expansion fails or produces no usable expanded lists.

Expected:

* retrieval continues with the `q` plan;
* output reports the fallback;
* output preserves any expansion metadata generated before fallback.

### Test 12: Vector ranks are global across lookups

Given:

* multiple lookups return vector candidates;
* candidates use different configured vector thresholds.

Expected:

* each lookup threshold is preserved;
* retained candidates are globally trimmed and ranked after merging lookups;
* deterministic lookup, path, and chunk tie-breakers are used.

### Test 13: SQLite connections are not shared concurrently

Given:

* vector and BM25 lists execute in parallel against the same physical SQLite table.

Expected:

* concurrent operations do not use the same `SqliteIndex` instance;
* retrieval uses one bounded worker pool and never exceeds `RETRIEVAL_THREADS_MAX`.

### Test 14: Input validation

Expected:

* empty and whitespace-only queries are rejected;
* `top_n <= 0` and `top_n > MAX_TOP_N` are rejected;
* an empty resolved lookup list is rejected;
* `/similar` rejects an empty `note` and invalid `topN`;
* HTTP returns `400` JSON errors;
* CLI exits nonzero with an actionable message.

### Test 15: Lookup-name validation

Given:

* a config contains a blank lookup name or duplicate lookup names.

Expected:

* config loading fails instead of silently overwriting `path_map`.

### Test 16: Chat-provider failure does not disable `q`

Given:

* embedding-provider requirements are satisfied;
* chat-provider credentials are missing or expansion raises.

Expected:

* `q`, `/similar`, and `run-query` continue to work;
* `q_plus` returns the `q` fallback with expansion metadata.

### Test 17: Response-shape touchpoints

Expected:

* `q.html` renders file-level results using `anchor_chunk`;
* `graph.html` sends initial searches and expansions to `/similar` only using the `note` request field;
* `graph.html`, `random.html`, and `reader.html` continue rendering chunk-shaped `/similar` results;
* graph Search+ and synthesis UI controls are absent.

### Test 18: CLI output formatting

Expected:

* `run-query --help` does not expose `--mode`;
* concise, full, JSON, JSONL, and text output formats render file-level results using anchor chunks.

### Test 19: Deterministic source-list ties

Given:

* BM25 or vector candidates have equal raw scores;
* parallel workers finish in different orders.

Expected:

* source-list ranks and final file order remain stable.

### Test 20: Backend failures are not hidden

Given:

* vector or BM25 execution raises for `q` or `q_plus`.

Expected:

* retrieval fails instead of returning a partial backend result set;
* only expansion-generation failures trigger the `q_plus` fallback.

## 16. Implementation sequence

1. Introduce query plan data structure.
2. Implement `build_q_plan`.
3. Implement `build_q_plus_plan`.
4. Refactor retrieval execution to return source-list annotated chunk candidates.
5. Replace existing fusion with weighted RRF fusion.
6. Add deterministic chunk-level boosts.
7. Add file-level aggregation.
8. Add shared input validation, lookup-name validation, and deferred chat-provider validation.
9. Update HTTP `/q`, HTTP `/q_plus`, and `run-query` to use the shared `Retriever`.
10. Update `q.html` file cards to use anchor chunks; route `graph.html` through `/similar` only.
11. Remove synthesis UI, endpoint, requires, and documentation.
12. Add debug output.
13. Add synthetic retrieval, route, CLI, and UI smoke tests.
14. Tune constants based on real notes.

## 17. Important implementation rule

Do not tune weights blindly until debug output exists.

The first implementation should prioritize explainability:

* why this chunk matched;
* which source list found it;
* what its rank was;
* how much RRF contributed;
* what boosts applied;
* why this file outranked another file.

Only after this visibility exists should weights be adjusted.
