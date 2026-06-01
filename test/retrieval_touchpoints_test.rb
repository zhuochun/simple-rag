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
refute_includes server, 'post "/synthesize"'

assert_includes query_cli, "build_retriever.retrieve_q(lookup_paths, query"
assert_includes query_cli, "anchor_chunk: concise_chunk(file[:anchor_chunk]"
refute_includes query_cli, "--mode"

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
refute_includes readme, "--mode"
refute_includes library, 'require "server/synthesizer"'
assert_includes llm, "ensure_chat_provider_ready!"
raise "Synthesizer file still exists" if File.exist?(File.join(ROOT, "server/synthesizer.rb"))

puts "retrieval_touchpoints_test: passed"
