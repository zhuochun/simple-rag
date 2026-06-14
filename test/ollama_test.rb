require "json"

require_relative "../llm/ollama"

Response = Struct.new(:code, :body)

def assert_equal(expected, actual)
  raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

captured = []
original_http_post = Object.instance_method(:http_post)
Object.send(:define_method, :http_post) do |_url, _auth, data|
  captured << data
  Response.new("200", JSON.generate("embedding" => [1.0, 0.0]))
end
Object.send(:private, :http_post)

begin
  assert_equal [1.0, 0.0], ollama_embedding("alpha", "model", "http://localhost:11434/api/embeddings")
  assert_equal "70m", captured.last["keep_alive"]

  ollama_embedding("alpha", "model", "http://localhost:11434/api/embeddings", "keep_alive" => "5m")
  assert_equal "5m", captured.last["keep_alive"]
ensure
  Object.send(:define_method, :http_post, original_http_post)
  Object.send(:private, :http_post)
end

puts "ollama_test: passed"
