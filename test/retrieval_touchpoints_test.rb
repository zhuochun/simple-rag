ROOT = File.expand_path("..", __dir__)

def read_repo(path)
  File.read(File.join(ROOT, path))
end

def assert_includes(text, expected)
  raise "Expected #{expected.inspect}" unless text.include?(expected)
end

def assert_equal(expected, actual)
  raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

def refute_includes(text, expected)
  raise "Unexpected #{expected.inspect}" if text.include?(expected)
end

server = read_repo("exe/run-server")
index_cli = read_repo("exe/run-index")
query_cli = read_repo("exe/run-query")
query_ui = read_repo("exe/public/q.html")
graph_ui = read_repo("exe/public/graph.html")
readme = read_repo("README.md")
library = read_repo("lib/simple_rag.rb")
llm = read_repo("llm/llm.rb")

assert_includes server, 'RETRIEVER.retrieve_q(lookup_paths, data["q"]'
assert_includes server, 'RETRIEVER.retrieve_q_plus(lookup_paths, data["q"]'
assert_includes server, 'RETRIEVER.validate_inputs!(lookup_paths, note, top_n)'
assert_includes server, 'OllamaService.ensure_started(CONFIG, sections: [:embedding])'
assert_includes server, 'get "/health"'
refute_includes server, 'post "/read_url"'
refute_includes server, 'post "/synthesize"'

assert_includes query_cli, "build_retriever.retrieve_q(lookup_paths, query"
assert_includes query_cli, "QueryServerClient.retrieve("
assert_includes query_cli, "QueryHelpers.compact_file_results(payload[:data], brief_chars: options[:brief_chars])"
assert_includes query_cli, "JSON.pretty_generate(concise ? payload[:data] : payload)"
refute_includes query_cli, "--mode"

assert_includes index_cli, "Readers own chunking through ChunkUtils"
assert_includes index_cli, '"--build-mode"'
assert_includes index_cli, '"--non-interactive"'
assert_includes index_cli, 'path_summary_line(path.name, matched: matched_files.length, read: read_files, created: created, skipped: skipped, errors: error_count)'
assert_includes index_cli, '"Match #{matched}, Read #{read} files | Create #{created}, Skip #{skipped}, Err #{errors} chunks"'
assert_includes index_cli, '"Files to read modified since #{format_scan_timestamp(last_scan_at)}: #{files_to_index.length}\\n"'
refute_includes index_cli, "summary_line(**totals)"
refute_includes index_cli, '"\\e[2J\\e[H"'
refute_includes index_cli, "normalize_index_chunks"
refute_includes index_cli, "INDEX_MAX_EMBED_TOKENS"

assert_includes query_ui, "const anchor = item.anchor_chunk || {};"
assert_includes query_ui, "resp.keyword_variants"
assert_includes query_ui, ".then(parseJsonOrThrow)"
refute_includes query_ui, "synthesize"

assert_equal 2, graph_ui.scan("fetch(api('/similar')").length
assert_includes graph_ui, ".then(parseJsonOrThrow)"
refute_includes graph_ui, "api('/q')"
refute_includes graph_ui, "api('/q_plus')"
refute_includes graph_ui, "search-plus-button"

refute_includes readme, "Synthesize"
assert_includes readme, "run-index --build-mode full"
refute_includes readme, "run-query --mode"
refute_includes library, 'require "server/synthesizer"'
assert_includes llm, "ensure_chat_provider_ready!"
raise "Synthesizer file still exists" if File.exist?(File.join(ROOT, "server/synthesizer.rb"))

puts "retrieval_touchpoints_test: passed"
