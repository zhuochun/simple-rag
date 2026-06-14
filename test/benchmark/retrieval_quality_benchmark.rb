#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "optparse"
require "time"

ROOT = File.expand_path("../..", __dir__)
DEFAULT_QUERY_FILE = File.join(__dir__, "retrieval_queries.txt")
DEFAULT_OUTPUT_DIR = File.join(ROOT, "tmp", "retrieval-quality")
CACHE_VERSION = 1
RETRIEVAL_CODE_FILES = [
  File.join(ROOT, "lib", "config_loader.rb"),
  File.join(ROOT, "lib", "query_helpers.rb"),
  File.join(ROOT, "llm", "llm.rb"),
  File.join(ROOT, "server", "retrieval_pipeline.rb"),
  File.join(ROOT, "server", "retriever.rb"),
  File.join(ROOT, "storage", "sqlite_index.rb"),
  __FILE__,
].freeze

require_relative "../../lib/config_loader"
require_relative "../../lib/ollama_service"
require_relative "../../lib/provider_env_validator"
require_relative "../../lib/query_helpers"
require_relative "../../server/retriever"

def parse_named_value(raw, option_name)
  name, value = raw.to_s.split("=", 2)
  raise ArgumentError, "#{option_name} must use NAME=VALUE" if name.to_s.strip.empty? || value.to_s.strip.empty?

  [name.strip, value.strip]
end

def parse_depth(raw)
  name, value = parse_named_value(raw, "--depth")
  vector, bm25 = value.split(",", 2).map { |item| Integer(item, 10) }
  raise ArgumentError, "--depth values must be > 0" unless vector > 0 && bm25 > 0

  { name: name, vector: vector, bm25: bm25 }
rescue ArgumentError, TypeError => e
  raise e if e.message.start_with?("--depth")

  raise ArgumentError, "--depth must use NAME=VECTOR,BM25 with positive integers"
end

def percentile(values, fraction)
  sorted = values.sort
  return 0.0 if sorted.empty?

  sorted[((sorted.length - 1) * fraction).ceil]
end

def result_key(item)
  [item[:lookup].to_s, item[:path].to_s]
end

def compare_results(baseline, candidate)
  baseline_keys = baseline.map { |item| result_key(item) }
  candidate_keys = candidate.map { |item| result_key(item) }
  overlap = baseline_keys & candidate_keys
  union = baseline_keys | candidate_keys
  baseline_ranks = baseline_keys.each_with_index.to_h
  candidate_ranks = candidate_keys.each_with_index.to_h
  displacement = overlap.map { |key| (baseline_ranks[key] - candidate_ranks[key]).abs }

  {
    overlap: overlap.length,
    jaccard: union.empty? ? 1.0 : (overlap.length.to_f / union.length).round(4),
    mean_rank_displacement: displacement.empty? ? nil : (displacement.sum.to_f / displacement.length).round(2),
    removed: (baseline_keys - candidate_keys).map { |lookup, path| { lookup: lookup, path: path } },
    added: (candidate_keys - baseline_keys).map { |lookup, path| { lookup: lookup, path: path } },
  }
end

def config_fingerprint(config_file, lookup_paths)
  digest = Digest::SHA256.new
  digest << File.binread(config_file)
  lookup_paths.each do |path|
    digest << path.name.to_s << path.db_file.to_s << path.db_table.to_s
    [path.db_file, "#{path.db_file}-wal"].each do |file|
      next unless File.exist?(file)

      stat = File.stat(file)
      digest << file << stat.size.to_s << stat.mtime.to_f.to_s
    rescue Errno::ENOENT
      next
    end
  end
  digest.hexdigest
end

def cache_key(scenario, queries, path_names, limit)
  Digest::SHA256.hexdigest(JSON.generate(
    version: CACHE_VERSION,
    retrieval_code: Digest::SHA256.hexdigest(RETRIEVAL_CODE_FILES.map { |file| File.binread(file) }.join),
    scenario: scenario[:name],
    config_fingerprint: scenario[:config_fingerprint],
    vector_depth: scenario[:depth][:vector],
    bm25_depth: scenario[:depth][:bm25],
    queries: queries,
    paths: path_names,
    limit: limit
  ))
end

def load_cache(path)
  JSON.parse(File.read(path), symbolize_names: true)
rescue Errno::ENOENT, JSON::ParserError
  nil
end

def set_config_constant(config)
  Object.send(:remove_const, :CONFIG) if Object.const_defined?(:CONFIG)
  Object.const_set(:CONFIG, config)
end

def run_scenario(scenario, queries, path_names, limit)
  config = scenario[:config]
  set_config_constant(config)
  missing_key = ProviderEnvValidator.missing_key_message(config, sections: [:embedding])
  raise missing_key if missing_key
  raise "Embedding provider is not ready" unless OllamaService.ensure_started(config, sections: [:embedding])

  lookup_paths = QueryHelpers.resolve_lookup_paths(config, path_names, default_to_search_default: true)
  executor = RetrievalExecutor.new(
    embedding_fn: method(:embedding),
    id_fn: method(:extract_id),
    url_fn: method(:extract_url),
    vector_candidate_depth: scenario[:depth][:vector],
    bm25_candidate_depth: scenario[:depth][:bm25]
  )
  retriever = Retriever.new(
    planner: QueryPlanner.new(chat_fn: method(:chat)),
    executor: executor
  )

  samples = queries.map do |query|
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    payload = retriever.retrieve_q(lookup_paths, query, top_n: limit)
    {
      query: query,
      elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round(1),
      results: payload[:data].map do |item|
        {
          lookup: item[:lookup],
          path: item[:path],
          score: item[:score].to_f.round(6),
        }
      end,
    }
  end
  {
    scenario: scenario[:name],
    config: scenario[:config_file],
    depth: scenario[:depth],
    paths: lookup_paths.map(&:name),
    samples: samples,
  }
ensure
  executor&.close
end

options = {
  configs: [],
  depths: [],
  paths: [],
  query_file: DEFAULT_QUERY_FILE,
  limit: 10,
  output_dir: DEFAULT_OUTPUT_DIR,
  refresh: false,
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby test/benchmark/retrieval_quality_benchmark.rb [options]"
  opts.on("-c", "--config NAME=FILE", "Named config; repeat to compare configs") do |raw|
    name, file = parse_named_value(raw, "--config")
    options[:configs] << { name: name, file: File.expand_path(file) }
  end
  opts.on("-d", "--depth NAME=VECTOR,BM25", "Fixed candidate depths; repeat to compare") do |raw|
    options[:depths] << parse_depth(raw)
  end
  opts.on("-p", "--paths NAMES", "Comma-separated lookup names") do |raw|
    options[:paths] = raw.split(",").map(&:strip).reject(&:empty?).uniq
  end
  opts.on("--queries FILE", "One query per line") { |file| options[:query_file] = File.expand_path(file) }
  opts.on("--limit N", Integer, "Top result count (default: 10)") { |value| options[:limit] = value }
  opts.on("--output-dir DIR", "Cache/report directory") { |dir| options[:output_dir] = File.expand_path(dir) }
  opts.on("--refresh", "Ignore cached scenario results") { options[:refresh] = true }
end.parse!

raise ArgumentError, "At least one --config NAME=FILE is required" if options[:configs].empty?
raise ArgumentError, "--limit must be > 0" unless options[:limit] > 0
options[:depths] = [{ name: "default", vector: nil, bm25: nil }] if options[:depths].empty?

queries = File.readlines(options[:query_file], chomp: true)
  .map(&:strip)
  .reject { |query| query.empty? || query.start_with?("#") }
raise "No benchmark queries found" if queries.empty?

scenarios = options[:configs].flat_map do |config_arg|
  raise "Config file not found: #{config_arg[:file]}" unless File.exist?(config_arg[:file])

  config = ConfigLoader.load_config(config_arg[:file], with_path_map: true)
  paths = QueryHelpers.resolve_lookup_paths(config, options[:paths], default_to_search_default: true)
  raise "No lookup paths selected for #{config_arg[:name]}" if paths.empty?
  fingerprint = config_fingerprint(config_arg[:file], paths)
  options[:depths].map do |depth|
    {
      name: "#{config_arg[:name]}/#{depth[:name]}",
      config_file: config_arg[:file],
      config: config,
      config_fingerprint: fingerprint,
      depth: depth,
    }
  end
end

FileUtils.mkdir_p(File.join(options[:output_dir], "cache"))
scenario_results = scenarios.map do |scenario|
  key = cache_key(scenario, queries, options[:paths], options[:limit])
  cache_file = File.join(options[:output_dir], "cache", "#{key}.json")
  cached = options[:refresh] ? nil : load_cache(cache_file)
  if cached
    cached[:cache] = "hit"
    cached
  else
    result = run_scenario(scenario, queries, options[:paths], options[:limit])
    File.write(cache_file, JSON.pretty_generate(result))
    result[:cache] = "miss"
    result
  end
end

baseline = scenario_results.first
comparisons = scenario_results.drop(1).map do |candidate|
  per_query = queries.map do |query|
    baseline_sample = baseline[:samples].find { |sample| sample[:query] == query }
    candidate_sample = candidate[:samples].find { |sample| sample[:query] == query }
    { query: query }.merge(compare_results(baseline_sample[:results], candidate_sample[:results]))
  end
  rank_displacements = per_query.filter_map { |item| item[:mean_rank_displacement] }
  {
    baseline: baseline[:scenario],
    candidate: candidate[:scenario],
    mean_overlap: (per_query.sum { |item| item[:overlap] }.to_f / per_query.length).round(2),
    mean_jaccard: (per_query.sum { |item| item[:jaccard] }.to_f / per_query.length).round(4),
    mean_rank_displacement: rank_displacements.empty? ? nil : (rank_displacements.sum / rank_displacements.length).round(2),
    queries: per_query,
  }
end

report = {
  generated_at: Time.now.iso8601,
  baseline: baseline[:scenario],
  query_file: options[:query_file],
  limit: options[:limit],
  scenarios: scenario_results,
  comparisons: comparisons,
}
timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
report_file = File.join(options[:output_dir], "report-#{timestamp}.json")
File.write(report_file, JSON.pretty_generate(report))

puts "Retrieval quality benchmark"
puts "baseline: #{baseline[:scenario]}"
scenario_results.each do |scenario|
  times = scenario[:samples].map { |sample| sample[:elapsed_ms] }
  puts format(
    "%-28s cache=%-4s median=%7.1fms p95=%7.1fms",
    scenario[:scenario],
    scenario[:cache],
    percentile(times, 0.50),
    percentile(times, 0.95)
  )
end
comparisons.each do |comparison|
  rank_text = comparison[:mean_rank_displacement].nil? ? "n/a" : format("%.2f", comparison[:mean_rank_displacement])
  puts format(
    "%-28s overlap=%.2f/%d jaccard=%.4f rank_delta=%s",
    comparison[:candidate],
    comparison[:mean_overlap],
    options[:limit],
    comparison[:mean_jaccard],
    rank_text
  )
end
puts "report: #{report_file}"
