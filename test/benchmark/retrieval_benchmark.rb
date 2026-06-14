#!/usr/bin/env ruby

BENCHMARK_STARTED_AT = Process.clock_gettime(Process::CLOCK_MONOTONIC)

require "json"
require "optparse"
require "ostruct"

ROOT = File.expand_path("../..", __dir__)

require_relative "../../lib/config_loader"
require_relative "../../lib/config_path_resolver"
require_relative "../../lib/ollama_service"
require_relative "../../lib/provider_env_validator"
require_relative "../../lib/query_helpers"
require_relative "../../server/retriever"

DEFAULT_QUERY_FILE = File.join(__dir__, "retrieval_queries.txt")

def monotonic_time
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def elapsed_ms(started_at)
  (monotonic_time - started_at) * 1000.0
end

def percentile(values, fraction)
  sorted = values.sort
  return 0.0 if sorted.empty?

  sorted[((sorted.length - 1) * fraction).ceil]
end

options = {
  config: nil,
  paths: [],
  query_file: DEFAULT_QUERY_FILE,
  runs: 3,
  warmup: 1,
  limit: 10,
  max_p95_ms: ENV["RAG_RETRIEVAL_MAX_P95_MS"]&.to_f,
  json: false,
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby test/benchmark/retrieval_benchmark.rb [options]"
  opts.on("-c", "--config FILE", "Config file") { |value| options[:config] = value }
  opts.on("-p", "--paths NAMES", "Comma-separated lookup names") do |value|
    options[:paths] = value.split(",").map(&:strip).reject(&:empty?).uniq
  end
  opts.on("--queries FILE", "One query per line") { |value| options[:query_file] = value }
  opts.on("--runs N", Integer, "Measured runs per query (default: 3)") { |value| options[:runs] = value }
  opts.on("--warmup N", Integer, "Warmup runs per query (default: 1)") { |value| options[:warmup] = value }
  opts.on("--limit N", Integer, "Top file limit (default: 10)") { |value| options[:limit] = value }
  opts.on("--max-p95-ms N", Float, "Fail when total p95 exceeds this budget") { |value| options[:max_p95_ms] = value }
  opts.on("--json", "Emit JSON") { options[:json] = true }
end.parse!

raise ArgumentError, "--runs must be > 0" unless options[:runs] > 0
raise ArgumentError, "--warmup must be >= 0" unless options[:warmup] >= 0

config_file = ConfigPathResolver.resolve_config_path(options[:config])
raise "Config file not found" unless config_file && File.exist?(config_file)

CONFIG = ConfigLoader.load_config(config_file, with_path_map: true)
lookup_paths = QueryHelpers.resolve_lookup_paths(CONFIG, options[:paths], default_to_search_default: true)
raise "No lookup paths selected" if lookup_paths.empty?
raise ProviderEnvValidator.missing_key_message(CONFIG, sections: [:embedding]) if ProviderEnvValidator.missing_key_message(CONFIG, sections: [:embedding])
raise "Embedding provider is not ready" unless OllamaService.ensure_started(CONFIG, sections: [:embedding])

queries = File.readlines(options[:query_file], chomp: true)
  .map(&:strip)
  .reject { |query| query.empty? || query.start_with?("#") }
raise "No benchmark queries found in #{options[:query_file]}" if queries.empty?

setup_ms = elapsed_ms(BENCHMARK_STARTED_AT)
warmup_samples = []
samples = []
embedding_ms = 0.0
embedding_fn = lambda do |text|
  started_at = monotonic_time
  embedding(text)
ensure
  embedding_ms += elapsed_ms(started_at)
end
executor = RetrievalExecutor.new(
  embedding_fn: embedding_fn,
  id_fn: method(:extract_id),
  url_fn: method(:extract_url)
)
retriever = Retriever.new(
  planner: QueryPlanner.new(chat_fn: method(:chat)),
  executor: executor
)

(options[:warmup] + options[:runs]).times do |run|
  queries.each do |query|
    embedding_before_ms = embedding_ms
    started_at = monotonic_time
    payload = retriever.retrieve_q(lookup_paths, query, top_n: options[:limit])
    total_ms = elapsed_ms(started_at)
    sample_embedding_ms = embedding_ms - embedding_before_ms
    sample = {
      query: query,
      total_ms: total_ms.round(1),
      embedding_ms: sample_embedding_ms.round(1),
      local_retrieval_ms: (total_ms - sample_embedding_ms).round(1),
      result_count: payload[:count],
    }
    if run < options[:warmup]
      warmup_samples << sample
    else
      samples << sample
    end
  end
end
executor.close

totals = samples.map { |sample| sample[:total_ms] }
summary = {
  config: config_file,
  paths: lookup_paths.map(&:name),
  setup_ms: setup_ms.round(1),
  query_count: queries.length,
  sample_count: samples.length,
  runs_per_query: options[:runs],
  latency_ms: {
    min: totals.min.round(1),
    median: percentile(totals, 0.50).round(1),
    p95: percentile(totals, 0.95).round(1),
    max: totals.max.round(1),
  },
  warmup_samples: warmup_samples,
  samples: samples,
}

if options[:json]
  puts JSON.pretty_generate(summary)
else
  puts "Retrieval benchmark: #{summary[:sample_count]} samples across #{summary[:paths].join(', ')}"
  puts format("one-time process setup: %.1fms", summary[:setup_ms])
  unless warmup_samples.empty?
    puts format(
      "warmup total ms: min=%.1f max=%.1f",
      warmup_samples.map { |sample| sample[:total_ms] }.min,
      warmup_samples.map { |sample| sample[:total_ms] }.max
    )
  end
  puts format(
    "total ms: min=%.1f median=%.1f p95=%.1f max=%.1f",
    summary[:latency_ms][:min],
    summary[:latency_ms][:median],
    summary[:latency_ms][:p95],
    summary[:latency_ms][:max]
  )
  samples.each do |sample|
    puts format(
      "%-24s total=%7.1f embedding=%7.1f local=%7.1f results=%d",
      sample[:query],
      sample[:total_ms],
      sample[:embedding_ms],
      sample[:local_retrieval_ms],
      sample[:result_count]
    )
  end
end

budget = options[:max_p95_ms]
if budget && budget > 0 && summary[:latency_ms][:p95] > budget
  warn format("p95 latency %.1fms exceeds %.1fms budget", summary[:latency_ms][:p95], budget)
  exit 1
end
