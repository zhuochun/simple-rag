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
    "exe/public/**/*",
    "exe/*"
  ]

  spec.bindir        = "exe"
  spec.executables   = ["run-index", "run-server"]
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "sinatra", "~> 4.1"
  spec.add_runtime_dependency "puma", "~> 6.5"

  spec.required_ruby_version = ">= 3.0"
end
