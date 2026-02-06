# simple-rag

Simple RAG on your knowledge bases. Only support Markdown Files.

Install the gem directly:

```bash
gem install simple-rag-zc
```

## Setup

- Setup Config JSON
  - Run `run-setup config.json` then edit the paths to absolute path.
- Run `run-index config.json` *Required
  - To generate embeddings for all files. It takes a while on the first time.
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

## Publishing

To release a new version to [RubyGems](https://rubygems.org), run:

```bash
gem build simple-rag.gemspec
gem push simple-rag-zc-$(ruby -Ilib -e 'require "simple_rag/version"; puts SimpleRag::VERSION').gem
```
