# frozen_string_literal: true

require_relative "lib/simple_rag/version"

Gem::Specification.new do |spec|
  spec.name          = "simple-rag-zc"
  spec.version       = SimpleRag::VERSION
  spec.authors       = ["Zhuochun"]
  spec.email         = ["zhuochun@hotmail.com"]

  spec.summary       = "RAG on Markdown Files"
  spec.description   = "Simple retrieval-augmented generation on markdown files"
  spec.license       = "MIT"
  spec.homepage      = "https://github.com/zhuochun/simple-rag"

  spec.files         = Dir[
    "README.md",
    "example_config.json",
    "lib/**/*",
    "llm/**/*",
    "readers/**/*",
    "server/**/*",
    "storage/**/*",
    "python/**/*",
    "vendor/sqlite-vec/**/*",
    "exe/public/**/*",
    "exe/*"
  ].reject { |file| file.include?("/__pycache__/") || file.end_with?(".pyc") }

  spec.bindir        = "exe"
  spec.executables   = ["run-index", "run-server", "run-index-map-py", "run-index-map-v2", "run-query"]
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "sinatra", "~> 4.1"
  spec.add_runtime_dependency "rackup", "~> 2.2"
  spec.add_runtime_dependency "fiddle", "~> 1.1"
  spec.add_runtime_dependency "ostruct", "~> 0.6"
  if Gem::Platform.local.to_s.include?("mingw-ucrt")
    spec.add_runtime_dependency "sqlite3", "~> 2.9.2"
    spec.add_runtime_dependency "webrick", "~> 1.9"
  else
    spec.add_runtime_dependency "sqlite3", "~> 1.6"
    spec.add_runtime_dependency "puma", "~> 6.5"
  end
  unless Gem::Platform.local.to_s.include?("mingw-ucrt")
    spec.add_runtime_dependency "sqlite-vec"
  end

  spec.required_ruby_version = ">= 3.0"
end
