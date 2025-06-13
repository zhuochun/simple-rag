# simple-rag

RAG on Markdown Files

- Use **Search** for standard retrieval
- Use **Search+** for agentic query expansion and fast text match
- Use **Synthesize** to combine retrieved notes

## Setup

- Setup Config JSON
- Run `run-index config.json` (processes each path concurrently)
- Run `run-server config.json` and open `http://localhost:4567/q.html`
- Open `http://localhost:4567/duplicate.html` to review duplicate clusters
- Open `http://localhost:4567/random.html` to explore notes randomly

## Publishing

To release a new version to [RubyGems](https://rubygems.org), run:

```bash
gem build simple-rag.gemspec
gem push simple-rag-zc-$(ruby -Ilib -e 'require "simple_rag/version"; puts SimpleRag::VERSION').gem
```

Install the gem directly:

```bash
gem install simple-rag-zc
```
