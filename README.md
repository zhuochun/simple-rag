# simple-rag

Simple RAG on your knowledge bases. Only support Markdown Files.

![cognition-map](https://github.com/zhuochun/simple-rag/blob/main/docs/cognition-map.png?raw=true)

Install the gem directly:

```bash
gem install simple-rag-zc
```

## Setup RAG

- Setup Config JSON *Required
  - Copy `example_config.json` to `config.json`, then edit the paths to absolute path.
  - All `run-*` executables default to `./config.json`, then `~/.config/simple-rag/config.json` if no config path is provided.
  
- SQLite index is required
  - Set per-path `db` as `sqlite_file_path@table_name`

- Run `run-index config.json` *Required
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

- Run `run-query "your question"` for CLI retrieval (LLM-friendly)
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

## Setup Map Generator

To create a fancy map like the screenshot, complete these additional steps:

- Setup Python map generator
  - Python 3.10+ is required for the faster map generator.
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
