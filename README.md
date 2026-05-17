# simple-rag

Simple RAG on your knowledge bases. Only support Markdown Files.

Install the gem directly:

```bash
gem install simple-rag-zc
```

## Setup

- Setup Config JSON
  - Copy `example_config.json` to `config.json`, then edit the paths to absolute path.
  - `map.path` is required if you want to use `run-index-map` / `map.html`.
- Run `run-index config.json` *Required
  - To generate embeddings for all files. It takes a while on the first time.
- Run `run-index-map config.json` *Optional but required for map.html
  - To cluster indexed notes into mountains and generate map data JSON.
  - Optional include-only paths:
    - set `map.includePaths` in config.json (array of `paths[].name`)
    - or call `run-index-map config.json journal,learning`
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

## Publishing

To release a new version to [RubyGems](https://rubygems.org), run:

```bash
gem build simple-rag.gemspec
gem push simple-rag-zc-$(ruby -Ilib -e 'require "simple_rag/version"; puts SimpleRag::VERSION').gem
```
