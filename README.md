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
  - To generate embeddings for all files. It takes a while on the first time.
  - To update embeddings whenever your files updated.
  
- Run `run-server config.json`
  - Open `http://localhost:4567/q.html` to search/ask from your knowledge bases
    - Use **Search** for standard retrieval
    - Use **Search+** for agentic query expansion and fast text match
  - Open `http://localhost:4567/duplicate.html` to review duplicate clusters
  - Open `http://localhost:4567/random.html` to explore notes randomly
  - Open `http://localhost:4567/graph.html` to explore search results as a graph

- Run `run-query "your question"` for CLI retrieval (LLM-friendly)
  - `run-query --help` shows usage and all configured `paths` (`name => dir`)
  - Uses the same standard retrieval pipeline as the web UI **Search** action
  - Default JSON output is a flat locator list with `path`, rounded `score`, anchor `chunk`, and brief `text`
  - Use `--full` for complete chunk text and retrieval debug details

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
