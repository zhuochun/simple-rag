# frozen_string_literal: true

require_relative "simple_rag/version"

# Adjust load path so require_relative works from gem
$LOAD_PATH.unshift File.expand_path("..", __dir__)

module SimpleRag
end

require "llm/llm"
require "readers/reader"
require "server/retriever"
require "server/synthesizer"
require "server/discuss"
