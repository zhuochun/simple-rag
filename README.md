# simple-rag

Simple RAG on your knowledge bases. Only support Markdown Files.

Install the gem directly:

```bash
gem install simple-rag-zc
```

## Setup

- Setup Config JSON
  - Copy `example_config.json` to `config.json`, then edit the paths to absolute path.
  - `map.path` is required if you want to use `run-index-map-py` / `map.html`.
  - All `run-*` executables default to `./config.json`, then `~/.config/simple-rag/config.json` if no config path is provided.
- Setup Python map generator
  - Python 3.10+ is required for the faster map generator.
  - From the repo root, install the Python package and dependencies:

```bash
python -m pip install -e python
```

- Run `run-index config.json` *Required
  - To generate embeddings for all files. It takes a while on the first time.
- Run `run-index-map-py config.json` *Optional but required for map.html
  - Preferred map generator. It clusters indexed notes into mountains and writes the map data JSON.
  - Optional include-only paths:
    - set `map.includePaths` in config.json (array of `paths[].name`)
    - or call `run-index-map-py config.json journal,learning`
  - For faster iteration, run the two stages separately:

```bash
run-index-map-py config.json --step clusters
run-index-map-py config.json --step labels
```

  - Or run both stages in one command:

```bash
run-index-map-py config.json --step all
```

  - Label generation uses concurrent LLM requests. Tune it with either `map.labelWorkers` in `config.json` or `--label-workers`:

```bash
run-index-map-py config.json --step labels --label-workers 6
```

  - The older Ruby `run-index-map` command is still available as a fallback, but the Python version is the recommended path.
- Optional migration from JSONL to SQLite tables
  - Set per-path `db` as `sqlite_file_path@table_name`
  - Run `run-migrate config.json` to migrate every path that has both `out` and `db`
- Run `run-server config.json`
  - Open `http://localhost:4567/q.html` to search/ask from your knowledge bases
    - Use **Search** for standard retrieval
    - Use **Search+** for agentic query expansion and fast text match
    - Use **Synthesize** to combine retrieved notes
  - Open `http://localhost:4567/duplicate.html` to review duplicate clusters
  - Open `http://localhost:4567/random.html` to explore notes randomly
  - Open `http://localhost:4567/graph.html` to explore search results as a graph
  - Open `http://localhost:4567/map.html` to explore knowledge mountains and click dots into `q.html`
- Run `run-query "your question"` for CLI retrieval (LLM-friendly)
  - `run-query --help` shows usage and all configured `paths` (`name => dir`)
  - Modes: `--mode embedding` (default), `--mode bm25`, `--mode hybrid`
  - Default output is concise brief chunks; use `--full` for complete chunk text

## Publishing

To release a new version to [RubyGems](https://rubygems.org), run:

```bash
gem build simple-rag.gemspec
gem push simple-rag-zc-$(ruby -Ilib -e 'require "simple_rag/version"; puts SimpleRag::VERSION').gem
```
