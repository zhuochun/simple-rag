#!/usr/bin/env ruby

require "json"
require "optparse"
require "tmpdir"

require_relative "../../lib/config_loader"
require_relative "../../server/retrieval_pipeline"

def monotonic_time
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def percentile(values, fraction)
  sorted = values.sort
  return 0.0 if sorted.empty?

  sorted[((sorted.length - 1) * fraction).ceil]
end

def elapsed_ms(started)
  (monotonic_time - started) * 1000.0
end

def representative_plan
  QueryPlan.new(
    original_query: "representative query",
    semantic_rewrite: nil,
    keyword_variants: [],
    lists: [
      {
        name: "vec:original",
        backend: "vector",
        query_type: "original",
        query: "representative query",
        phrase: false,
        weight: 1.2,
      },
      {
        name: "bm25:phrase",
        backend: "bm25",
        query_type: "original",
        query: "representative query",
        phrase: true,
        weight: 1.2,
      },
    ]
  )
end

def representative_result
  text = "representative retrieved note text " * 60
  data = 10.times.map do |file_index|
    chunks = 3.times.map do |chunk|
      {
        chunk: chunk,
        score: 0.8 - chunk * 0.1,
        text: text,
        sources: ["vec:original"],
        evidence: [],
      }
    end
    {
      path: "note-#{file_index}.md",
      id: "note-#{file_index}",
      lookup: "docs",
      url: nil,
      score: 0.9 - file_index * 0.01,
      anchor_chunk: chunks.first,
      matched_chunks: chunks,
      source_summary: {
        source_lists: ["vec:original"],
        has_original_match: true,
      },
      debug: {},
    }
  end
  {
    query: "representative query",
    requested_mode: "q",
    mode: "q",
    fallback: nil,
    semantic_rewrite: nil,
    keyword_variants: [],
    count: 10,
    data: data,
  }
end

def record_once(writer, path, plan, result)
  started = monotonic_time
  session = writer.start(
    query: "representative query",
    requested_mode: "q",
    lookup_paths: [path],
    top_n: 10,
    started_at: Time.now.utc,
    started_monotonic: started
  )
  session.retrieval_observer&.call({
    "embeddings" => [{ "source_list" => "vec:original", "cache_status" => "miss", "status" => "ok", "stage" => "embedding", "elapsed_ms" => 50.0 }],
    "searches" => %w[vector bm25].flat_map do |backend|
      %w[notes talks papers].map do |lookup|
        {
          "source_list" => backend == "vector" ? "vec:original" : "bm25:phrase",
          "backend" => backend, "lookup" => lookup, "status" => "ok", "stage" => "search",
          "elapsed_ms" => 5.0, "pool_wait_ms" => 0.01, "open_ms" => 0.0,
          "connection" => "reused", "search_ms" => 4.9, "candidate_count" => 64,
        }
      end
    end,
  })
  session.success(plan: plan, result: result, effective_mode: "q")
  elapsed_ms(started)
end

options = {
  warmup: 5,
  samples: 100,
  max_p95_ms: 25.0,
  json: false,
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby test/benchmark/query_trace_overhead_benchmark.rb [options]"
  opts.on("--warmup N", Integer, "Warmup samples (default: 5)") { |value| options[:warmup] = value }
  opts.on("--samples N", Integer, "Measured samples (default: 100)") { |value| options[:samples] = value }
  opts.on("--max-p95-ms N", Float, "Fail when overhead p95 exceeds this budget (default: 25)") do |value|
    options[:max_p95_ms] = value
  end
  opts.on("--json", "Emit JSON") { options[:json] = true }
end.parse!

raise ArgumentError, "--warmup must be >= 0" unless options[:warmup] >= 0
raise ArgumentError, "--samples must be > 0" unless options[:samples] > 0
raise ArgumentError, "--max-p95-ms must be > 0" unless options[:max_p95_ms] > 0

summary = Dir.mktmpdir("query-trace-overhead-") do |dir|
  index_file = File.join(dir, "index.sqlite")
  config_file = File.join(dir, "config.json")
  trace_file = File.join(dir, "query-traces.sqlite")
  File.binwrite(index_file, "representative-index-state")
  File.write(config_file, JSON.generate(
    paths: [{
      name: "docs",
      db: "#{index_file}@chunks",
      searchDefault: true,
    }],
    queryLog: {
      enabled: true,
      db: trace_file,
    }
  ))
  config = ConfigLoader.load_config(config_file, with_path_map: true)
  components = []
  enabled_writer = SimpleRag::QueryTraceWriter.build(
    config: config,
    config_file: config_file,
    source: "server",
    overhead_observer: ->(sample) { components << sample }
  )
  disabled_writer = SimpleRag::NullQueryTraceWriter.new
  path = config.paths.first
  plan = representative_plan
  result = representative_result

  options[:warmup].times do
    record_once(disabled_writer, path, plan, result)
    record_once(enabled_writer, path, plan, result)
  end
  components.clear

  disabled_samples = []
  enabled_samples = []
  options[:samples].times do
    disabled_samples << record_once(disabled_writer, path, plan, result)
    enabled_samples << record_once(enabled_writer, path, plan, result)
  end
  enabled_writer.close

  unless components.length == options[:samples]
    raise "Expected #{options[:samples]} component samples, got #{components.length}"
  end

  overhead_samples = enabled_samples.zip(disabled_samples).map do |enabled, disabled|
    [enabled - disabled, 0.0].max
  end
  {
    top_n: 10,
    warmup: options[:warmup],
    samples: options[:samples],
    result_bytes: JSON.generate(result).bytesize,
    enabled_ms: {
      median: percentile(enabled_samples, 0.50).round(3),
      p95: percentile(enabled_samples, 0.95).round(3),
      max: enabled_samples.max.round(3),
    },
    disabled_ms: {
      median: percentile(disabled_samples, 0.50).round(3),
      p95: percentile(disabled_samples, 0.95).round(3),
      max: disabled_samples.max.round(3),
    },
    overhead_ms: {
      median: percentile(overhead_samples, 0.50).round(3),
      p95: percentile(overhead_samples, 0.95).round(3),
      max: overhead_samples.max.round(3),
    },
    component_p95_ms: {
      projection: percentile(components.map { |sample| sample[:projection_ms] }, 0.95).round(3),
      serialization: percentile(components.map { |sample| sample[:serialization_ms] }, 0.95).round(3),
      insertion: percentile(components.map { |sample| sample[:insertion_ms] }, 0.95).round(3),
      persistence_total: percentile(components.map { |sample| sample[:total_ms] }, 0.95).round(3),
    },
    budget_p95_ms: options[:max_p95_ms],
  }
ensure
  enabled_writer&.close
end

if options[:json]
  puts JSON.pretty_generate(summary)
else
  puts "Query trace overhead benchmark"
  puts "top_n=#{summary[:top_n]} samples=#{summary[:samples]} result_bytes=#{summary[:result_bytes]}"
  puts format(
    "caller overhead ms: median=%.3f p95=%.3f max=%.3f budget=%.3f",
    summary[:overhead_ms][:median],
    summary[:overhead_ms][:p95],
    summary[:overhead_ms][:max],
    summary[:budget_p95_ms]
  )
  puts format(
    "component p95 ms: projection=%.3f serialization=%.3f insertion=%.3f persistence_total=%.3f",
    summary[:component_p95_ms][:projection],
    summary[:component_p95_ms][:serialization],
    summary[:component_p95_ms][:insertion],
    summary[:component_p95_ms][:persistence_total]
  )
end

if summary[:overhead_ms][:p95] > options[:max_p95_ms]
  warn format(
    "query trace overhead p95 %.3fms exceeds %.3fms budget",
    summary[:overhead_ms][:p95],
    options[:max_p95_ms]
  )
  exit 1
end
