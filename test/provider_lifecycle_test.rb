require "ostruct"

require_relative "../lib/ollama_service"
require_relative "../lib/provider_env_validator"
require_relative "../llm/llm"

def assert_equal(expected, actual)
  raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

def assert_raises(error_class)
  yield
  raise "Expected #{error_class}, but nothing was raised"
rescue error_class => e
  e
end

config = OpenStruct.new(
  embedding: OpenStruct.new(provider: "openai", url: "https://example.test/embeddings"),
  chat: OpenStruct.new(provider: "ollama", url: "http://localhost:11434/api/chat")
)

original_openai_key = ENV.delete("DOT_OPENAI_KEY")
begin
  embedding_error = ProviderEnvValidator.missing_key_message(config, sections: [:embedding])
  raise "Expected embedding key error" unless embedding_error.include?("DOT_OPENAI_KEY")
  assert_equal nil, ProviderEnvValidator.missing_key_message(config, sections: [:chat])
ensure
  ENV["DOT_OPENAI_KEY"] = original_openai_key if original_openai_key
end

assert_equal nil, OllamaService.ollama_api_url(config, sections: [:embedding])
assert_equal "http://127.0.0.1:11434/api/tags", OllamaService.ollama_api_url(config, sections: [:chat])

chat_config = OpenStruct.new(
  embedding: OpenStruct.new(provider: "ollama"),
  chat: OpenStruct.new(provider: "openrouter")
)
original_openrouter_key = ENV.delete("DOT_OPENROUTER_KEY")
begin
  Object.const_set(:CONFIG, chat_config)
  error = assert_raises(RuntimeError) { ensure_chat_provider_ready! }
  raise "Expected lazy chat key error" unless error.message.include?("DOT_OPENROUTER_KEY")
ensure
  Object.send(:remove_const, :CONFIG) if Object.const_defined?(:CONFIG, false)
  ENV["DOT_OPENROUTER_KEY"] = original_openrouter_key if original_openrouter_key
end

puts "provider_lifecycle_test: passed"
