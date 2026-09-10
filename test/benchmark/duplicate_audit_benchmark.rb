require "optparse"
require_relative "../../lib/config_loader"
require_relative "../../lib/duplicate_audit"

options = {paths: []}
OptionParser.new do |p|
  p.on("--config FILE") { |v| options[:config] = v }
  p.on("--paths NAMES") { |v| options[:paths] = v.split(",") }
  p.on("--reference", "Use original full-vector per-chunk search for comparison") { options[:reference] = true }
  p.on("--compare", "Verify both searches against the same in-memory snapshot") { options[:compare] = true }
end.parse!
abort "--config is required" unless options[:config]
abort "Unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
abort "Choose --reference or --compare" if options[:reference] && options[:compare]
config = ConfigLoader.load_config(options[:config])
unknown = options[:paths] - config.paths.map(&:name)
abort "Unknown paths: #{unknown.join(', ')}" unless unknown.empty?
paths = config.paths.select { |p| options[:paths].empty? || options[:paths].include?(p.name) }
TIMINGS = Hash.new(0.0)
REFERENCE = options[:reference]
COMPARE = options[:compare]
NEIGHBORHOOD_DIGEST = Digest::SHA256.new
REFERENCE_DIGEST = Digest::SHA256.new
module AuditTiming
  def load_path(...)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    super
  ensure
    TIMINGS[:load_seconds] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end
end
module VectorTiming
  def each_vector_neighborhood(k, threshold: nil)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    signature = lambda do |row, hits|
      qualifying = hits.select { |hit| hit["score"] >= threshold }.map { |hit| hit.values_at("path", "chunk", "score") }.sort
      [row.values_at("path", "chunk"), qualifying].to_json
    end
    consume = lambda do |row, hits|
      NEIGHBORHOOD_DIGEST.update(signature.call(row, hits))
      yield row, hits
    end
    if REFERENCE
      each_item { |row| consume.call(row, vector_search(row["embedding"], k)) }
    else
      super(k, threshold: threshold, &consume)
    end
    TIMINGS[:search_seconds] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    if COMPARE
      reference_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      each_item { |row| REFERENCE_DIGEST.update(signature.call(row, vector_search(row["embedding"], k))) }
      TIMINGS[:reference_search_seconds] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - reference_start
      raise "Optimized neighborhoods differ from reference on the same snapshot" unless REFERENCE_DIGEST.hexdigest == NEIGHBORHOOD_DIGEST.hexdigest
    end
  end
end
SimpleRag::DuplicateAudit.prepend(AuditTiming)
SqliteIndex.prepend(VectorTiming)
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
report = SimpleRag::DuplicateAudit.new(paths: paths).run
puts JSON.pretty_generate(timings: TIMINGS.merge(total_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - start),
                          engine: REFERENCE ? "reference" : "optimized", stats: report[:stats],
                          same_snapshot_verified: !!COMPARE,
                          neighborhood_digest: NEIGHBORHOOD_DIGEST.hexdigest,
                          result_digest: Digest::SHA256.hexdigest(report[:clusters].to_json))
