require "json"

require_relative "../llm/ollama"

Response = Struct.new(:code, :body)

def assert_equal(expected, actual)
  raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

captured = []
original_post_json = LlmHttp.method(:post_json!)
LlmHttp.define_singleton_method(:post_json!) do |_url, data, **_options|
  captured << data
  Response.new("200", JSON.generate("embedding" => [1.0, 0.0]))
end

begin
  assert_equal [1.0, 0.0], ollama_embedding("alpha", "model", "http://localhost:11434/api/embeddings")
  assert_equal "70m", captured.last["keep_alive"]

  ollama_embedding("alpha", "model", "http://localhost:11434/api/embeddings", "keep_alive" => "5m")
  assert_equal "5m", captured.last["keep_alive"]
ensure
  LlmHttp.define_singleton_method(:post_json!, original_post_json)
end

puts "ollama_test: passed"
