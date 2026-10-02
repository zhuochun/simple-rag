# simple-rag

Search and ask questions across your Markdown knowledge bases.

![cognition-map](https://github.com/zhuochun/simple-rag/blob/main/docs/cognition-map.png?raw=true)

Install the gem directly:

```bash
gem install simple-rag-zc
```

## Setup RAG

- Create the required JSON configuration.
  - Copy `example_config.json` to `config.json`, then set absolute paths.
  - All `run-*` executables default to `./config.json`, then `~/.config/simple-rag/config.json` if no config path is provided.
  
- Configure the required SQLite index.
  - Set per-path `db` as `sqlite_file_path@table_name`

- Build the index with `run-index config.json`.
  - By default this uses delta build mode: after the first complete scan, it only reads files modified since the last completed scan.
  - Delta mode automatically falls back to a full build when the index DB or per-path scan timestamp is missing.
  - Use `run-index --build-mode full config.json` to scan all matching docs and rebuild/prune from the complete current file set.
  - Use `run-index --non-interactive config.json` to print only per-path final summaries.
  - Index summaries report matched files separately from read files; in delta mode, read files are the changed-file workload.
  
- Run `run-server config.json`
  - Concurrent cache misses for the same query share one embedding request; different queries can proceed independently.
  - SQLite connections are reused across retrieval, similarity, random, and map-note requests. Restart the server after replacing index database files or changing the embedding model.
  - Open `http://localhost:4567/q.html` to search/ask from your knowledge bases
    - Use **Search** for standard retrieval
    - Use **Search+** for agentic query expansion and fast text match
  - Open `http://localhost:4567/duplicate.html` to review duplicate clusters
  - Open `http://localhost:4567/random.html` to explore notes randomly
  - Open `http://localhost:4567/graph.html` to explore search results as a graph

- Run `run-query "your question"` for CLI retrieval.
  - `run-query --help` shows usage and all configured `paths` (`name => dir`)
  - Uses the same standard retrieval pipeline as the web UI **Search** action
  - Automatically uses a matching server at `http://127.0.0.1:4567`; otherwise it retrieves locally
  - Set `RAG_SERVER_URL` to use a different server URL
  - Loopback HTTP health probes use a nonblocking connection with a 200 ms connect timeout and a 500 ms read timeout, avoiding the Windows blocking-connect delay when the server is absent.
  - Default JSON output is a flat list with `path` (collection), `file`, rounded `score`, and `matched_chunks` previews
  - Previews prefer a whole query-matching paragraph that fits `--brief-chars` (default 300), otherwise the start of the chunk. Omitted surrounding text is marked with `...`.
  - Use `--full` for complete chunk text and retrieval debug details

On Windows, use the repository's [background server launcher](https://github.com/zhuochun/simple-rag/blob/main/scripts/start-server.ps1) for repeated CLI queries. From a repository checkout:

```powershell
.\scripts\start-server.ps1 -Config '.\config.json'
```

The helper binds to `127.0.0.1:4567`, reuses an already matching server, and refuses
to replace a server using another configuration. It prints the PID and writes
process logs under `%LOCALAPPDATA%\simple-rag`. Run it again after signing in or
rebooting; it does not install a login task. To stop it, use `Stop-Process -Id <PID>`
with the printed PID after checking that it still belongs to this server.
Restart after replacing index files, changing configuration, or updating server code. Use `-Port` for
another port and set `RAG_SERVER_URL` accordingly for clients.

- Optionally record real queries for later retrieval evaluation:

```json
{
  "queryLog": {
    "enabled": true,
    "db": "D:\\Data\\simple-rag\\query-traces.sqlite"
  }
}
```

  - Logging is disabled unless `queryLog.enabled` is `true`.
  - New traces include `plan_json.retrieval`: embedding/cache timings and per-backend connection, wait, opening and search timings. Existing version-1 trace databases remain compatible; older records lack these details.
  - Relative database paths resolve from the config file directory.
  - The trace database must be separate from every retrieval-index database.
  - Traces contain raw queries and retrieved note text. Store the database as private user data and do not commit it.
  - Server queries and server-backed `run-query` calls are recorded once by the server; local CLI fallback records locally.
  - See the [query trace logging specification](https://github.com/zhuochun/simple-rag/blob/main/docs/20260723-query-trace-logging.md) for the schema, timing semantics, and failure behavior.
  - Verify synchronous trace overhead against its 25 ms p95 budget:

```bash
ruby test/benchmark/query_trace_overhead_benchmark.rb
```

- Benchmark retrieval latency with a representative query set:

```bash
ruby test/benchmark/retrieval_benchmark.rb --config config.json
```

  - Reports minimum, median, p95, and maximum latency plus planning, embedding, and local retrieval time.
  - Use `--mode q_plus` to benchmark expanded search, including its concurrent rewrite and keyword prompts. Effective modes and fallback counts distinguish successful expansions from fallback searches.
  - Concurrent prompts can reduce provider wait time; gains depend on whether the provider can serve both requests concurrently.
  - Use `--max-p95-ms 2000` or `RAG_RETRIEVAL_MAX_P95_MS=2000` to fail on a latency regression.

- Compare top-10 retrieval results across configs and candidate depths:

```bash
ruby test/benchmark/retrieval_quality_benchmark.rb ^
  --config qwen=config-v2.json ^
  --config other=config.json ^
  --depth previous=120,200 ^
  --depth current=64,100
```

  - Configs and depth profiles are combined into comparison scenarios.
  - Reports top-10 overlap, Jaccard similarity, rank displacement, and latency.
  - Cached scenario results and timestamped JSON reports are written under `tmp/retrieval-quality`.
  - Use `--refresh` to ignore cached results.

## Discover duplicate candidates from existing embeddings

`run-duplicates` discovers document pairs across the collections defined by any
simple-rag config, without a query. It is not tied to a particular knowledge base.
It opens source SQLite databases read-only, uses a disposable in-memory vector
index, and never calls an embedding/chat API or changes notes, indexes, dismissals,
or query logs. No API credentials or running server are needed.

From a checkout on Windows (after `bundle install`):

```powershell
ruby exe/run-duplicates --config config.json --threshold 0.95 --coverage 0.8 --limit 20
ruby exe/run-duplicates --config config.json --paths collection-a,collection-b --format json --limit 50
ruby exe/run-duplicates --config config.json --prefix 'D:/Knowledge/notes' --format json
```

Replace example collection names and filesystem paths with those in your config.
Installed gems expose the same command as `run-duplicates`. `--help` lists options.
`--paths` accepts exact configured collection names; by default **all configured
paths** are selected, including those without `searchDefault`. `--prefix` is a
filesystem file/directory boundary filter, not a substring or glob. Both members
must be inside the selected corpus. Paths follow existing config conventions:
use absolute paths; relative DB/source paths resolve from the process directory.

The algorithm deliberately returns **overlapping two-document complete-link
clusters**. A–B and B–C remain separate clusters; they never imply A–C. This keeps
every accepted pair reviewable without arbitrary greedy grouping hiding a bridge.
Cluster IDs are hashes of the sorted canonical member paths.

1. Load selected indexed chunks, canonicalize file identity, exclude same-document
   matches, and normalize existing vectors. Conflicting overlapping index rows,
   invalid/zero vectors, mixed dimensions, and missing chunk text fail the run.
2. Use sqlite-vec cosine nearest neighbors for each chunk (default `--neighbors 64`,
   including self and same-document hits). Keep cross-document matches at or above
   `--threshold` (default 0.95). This is bounded candidate discovery, not an exhaustive
   threshold join. Dense neighborhoods and large documents can hide matches.
   The report warns when a query hits the cap above threshold. Narrow the corpus or
   increase `--neighbors` (maximum 4096) when recall matters.
   For dimensions at least 512 and thresholds at least 0.8, a normalized 256-coordinate
   prefix prefilter reduces full-dimensional comparisons. Prefix Euclidean distance
   is a lower bound on full distance; cosine at least `t` requires full squared
   distance at most `2*(1-t)`. A conservative dimension-scaled float32 margin is
   included. Surviving candidates are scored using the original full vectors.
   If the prefix radius is too dense to enumerate within its cap, the query falls
   back to the full-vector search. This adds no approximate candidate cutoff.
   Equal full-vector distances straddling the neighbor cap also use the full-index
   search, preserving sqlite-vec's existing member selection for cutoff ties.
3. For each candidate document pair, greedily select one-to-one chunk matches in
   descending similarity, breaking ties by chunk indices. A single quotation cannot
   match multiple chunks to inflate coverage. This conservative matching is not an
   optimal bipartite assignment and can miss candidates with ambiguous alignments.
4. Require **both chunk-count coverage and indexed-character coverage on each
   document** to meet `--coverage` (default 0.8). A shared section in otherwise
   different multi-chunk documents normally fails this gate. Coverage is whole
   matched chunks, not token alignment: a shared quotation within a single chunk
   can still cause a false positive. Short/single-chunk notes and strongly related
   topics require particular care. Thresholds are heuristics, not calibrated duplicate
   probabilities, and changed chunk boundaries can cause false negatives.

Results sort by minimum bilateral character coverage, then mean matched cosine,
then canonical paths. Sorting, evidence selection, and IDs are deterministic for
unchanged inputs and runtime. `--limit` bounds returned clusters (default 20);
`--evidence` bounds representative chunk pairs (default 3); `--brief-chars` bounds
each snippet (default 240). The report includes qualifying totals and truncation.
Every cluster includes member paths, min/mean similarity, matched/total chunks and
characters for each member, and strongest representative snippets with cosine and
**zero-based indexed chunk positions**. Source line offsets are not stored and are
not invented; reader transformations mean snippets may differ from literal source.
JSON also includes the settings, per-index diagnostics, warnings, and scan counts.

Missing databases/tables are reported and skipped without creating them; missing
source files, files newer than the last completed scan, and matching files absent
from the index are counted. Absent files may have been intentionally filtered by
the reader. Missing scan timestamps mean unknown freshness. These checks use
filesystem metadata, not re-reading/re-chunking source content; preserved mtimes,
partial historical builds, changed reader settings, and unindexed source sections
can escape detection. Each database is read under its own snapshot; independently
updated databases need not represent the same point in time.

The current index schema stores vector dimension but **no embedding model
provenance**. Same-dimension mixed-model indexes cannot be detected, even when the
current config names one model. Only select indexes known to use the same model.
Warnings and skipped indexes make an empty result inconclusive. Malformed input
and invalid options exit nonzero; valid scans, including empty/partial scans with
diagnostics, exit zero.

Memory scales with indexed text/vectors and at most O(chunks × neighbors) candidate
matches, plus bounded returned evidence; no all-pairs similarity matrix is allocated.
sqlite-vec uses exact neighbor scans, so arithmetic remains quadratic in chunk count
(and linear in vector dimension). This targets a local corpus of thousands of
chunks; scope larger runs before increasing the candidate cap. No persistent
derived index or extra dependency is introduced.

Batch loading, cached file identities, prepared queries, and binary float32 vector
traversal avoid repeated JSON round trips and text payloads in neighbor searches.
Low-dimensional or low-threshold inputs use full-vector traversal directly; dense
or poorly discriminating prefixes may see little benefit or some overhead. The
worst-case arithmetic remains quadratic; the optimization does not weaken the
threshold, coverage requirement, or neighbor cap to obtain speed.

Measure your own config, including loading/search timings and a digest of all
above-threshold neighborhoods, with the offline benchmark. The reference mode
uses the original per-chunk full-vector search, allowing result comparison:

```powershell
ruby test/benchmark/duplicate_audit_benchmark.rb --config config.json
ruby test/benchmark/duplicate_audit_benchmark.rb --config config.json --compare
```

`--compare` runs both searches on the same in-memory snapshot, checks every
above-threshold neighborhood (identities and scores), and fails on disagreement.
It reports optimized and reference search times separately; total time includes
both searches. `--reference` runs only the original search with the current loader.
`--paths` optionally restricts a run to configured collection names. These measurements are
machine/corpus snapshots, not latency guarantees or duplicate-free certifications.

A local 5,924-chunk / 1,024-dimension snapshot took 63.1 seconds with the optimized
command (14.1 seconds loading, 49.0 searching), versus 131 seconds recorded for
the initial implementation. The configured collections contained 2,369 documents.
This sample is a performance fixture; the command has no collection-specific logic.
After the live indexes changed, a same-snapshot comparison on 5,950 chunks found
identical above-threshold neighborhoods and scores: optimized search 47.2 seconds,
reference search 64.8 seconds (27% less search time), with 14.1 seconds shared
loading time. Five document pairs qualified in that newer snapshot.

Run the offline behavioral and CLI tests with:

```powershell
ruby test/duplicate_audit_test.rb
```

**Clusters are human-review leads, never deletion or merge decisions.** Inspect
the full documents and provenance before taking any later action.

## Setup Map Generator

To create a map like the screenshot:

- Install the Python map generator.
  - Python 3.10+ is required.
  - From the repo root, install the Python package and dependencies:

```bash
python -m pip install -e python
```

- Update `config.json` on `map.path` fields.
  
- Run `run-index-map-v2 config.json`.
  - It clusters indexed notes into mountains and writes the map data JSON.
  - Optional include-only paths:
    - set `map.includePaths` in config.json (array of `paths[].name`)
    - or call `run-index-map-v2 config.json journal,learning`
  - For faster iteration, run graph-only output first:

```bash
run-index-map-v2 config.json --stage graph
```

  - Or run the full pipeline:

```bash
run-index-map-v2 config.json --stage all
```

  - Label generation uses concurrent LLM requests. Tune it with either `map.labelWorkers` in `config.json` or `--label-workers`:

```bash
run-index-map-v2 config.json --stage labels --label-workers 6
```

- Open `http://localhost:4567/map-v2.html` to explore knowledge mountains and click dots into `q.html`

## Publishing

To release a new version to [RubyGems](https://rubygems.org), run:

```bash
gem build simple-rag.gemspec
gem push simple-rag-zc-$(ruby -Ilib -e 'require "simple_rag/version"; puts SimpleRag::VERSION').gem
```

To test the version as a local install:

```bash
gem install simple-rag-zc-$(ruby -Ilib -e 'require "simple_rag/version"; puts SimpleRag::VERSION').gem
```
