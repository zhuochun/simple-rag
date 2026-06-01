require "digest"
require "fileutils"
require "json"

require_relative "../../readers/reader"

SMALL_CHUNK_TOKENS = 50
OVERSIZED_CHUNK_TOKENS = 1_000
REPRESENTATIVE_SAMPLES_PER_PATH = 5
ISSUE_SAMPLES_PER_KIND = 50

def report_dir
  base = File.join(__dir__, "readers_smoke-#{Time.now.strftime("%Y%m%d-%H%M")}")
  return base unless Dir.exist?(base)

  suffix = 2
  suffix += 1 while Dir.exist?("#{base}-#{suffix}")
  "#{base}-#{suffix}"
end

def markdown_chunk(file, chunk_index, tokens, chunk, note = nil)
  heading = "### `#{file}` chunk #{chunk_index} (#{tokens} tokens)"
  heading += " - #{note}" if note
  "#{heading}\n\n````text\n#{chunk}\n````\n"
end

def representative_chunks(chunks)
  return chunks if chunks.length <= REPRESENTATIVE_SAMPLES_PER_PATH

  indexes = [
    0,
    chunks.length / 4,
    chunks.length / 2,
    (chunks.length * 3) / 4,
    chunks.length - 1,
  ]
  indexes.uniq.map { |index| chunks[index] }
end

config_file = ARGV[0] || File.expand_path("../../config-v2.json", __dir__)
config = JSON.parse(File.read(config_file))
failed = false
output_dir = report_dir
FileUtils.mkdir_p(output_dir)
token_counter = Object.new.extend(ChunkUtils)
summary = [
  "# Configured Readers Smoke Report",
  "",
  "Config: `#{File.expand_path(config_file)}`",
  "",
  "Heuristics: small chunk < #{SMALL_CHUNK_TOKENS} tokens; oversized chunk > #{OVERSIZED_CHUNK_TOKENS} tokens.",
  "",
]
representative_report = ["# Representative Chunks", "", "These deterministic samples did not trigger the issue heuristics.", ""]
issues_report = [
  "# Potential Issues",
  "",
  "Heuristics are review aids, not test failures. Samples are capped per issue type.",
  "",
  "Thresholds: small chunk < #{SMALL_CHUNK_TOKENS} tokens; oversized chunk > #{OVERSIZED_CHUNK_TOKENS} tokens.",
  "",
]

config.fetch("paths").each do |path|
  source_dir = path.fetch("dir").tr("\\", "/")
  files = Dir.glob(File.join(source_dir, "**", "*.md"))
  reader_class = get_reader(path.fetch("reader"))
  errors = []
  empty_files = []
  duplicate_chunks = []
  issue_counts = Hash.new(0)
  issue_samples = Hash.new { |hash, key| hash[key] = [] }
  acceptable_chunks = []
  seen_chunks = {}
  chunk_count = 0
  indexed_files = 0

  if reader_class.nil?
    errors << ["-", "unknown reader #{path.fetch("reader")}"]
  else
    files.each do |file|
      begin
        chunks = reader_class.new(file).load.chunks
        chunk_count += chunks.length
        indexed_files += 1 unless chunks.empty?
        empty_files << file if chunks.empty?

        chunks.each_with_index do |chunk, chunk_index|
          tokens = token_counter.count_tokens(chunk)
          sample = [file, chunk_index, tokens, chunk]
          reasons = []
          reasons << "small chunk" if tokens < SMALL_CHUNK_TOKENS
          reasons << "oversized chunk" if tokens > OVERSIZED_CHUNK_TOKENS

          digest = Digest::SHA256.hexdigest(chunk)
          if seen_chunks.key?(digest)
            reasons << "duplicate chunk text"
            duplicate_chunks << [file, chunk_index, seen_chunks[digest]]
          else
            seen_chunks[digest] = "#{file} chunk #{chunk_index}"
          end

          if reasons.empty?
            acceptable_chunks << sample
          else
            reasons.each do |reason|
              issue_counts[reason] += 1
              issue_samples[reason] << sample if issue_samples[reason].length < ISSUE_SAMPLES_PER_KIND
            end
          end
        end
      rescue StandardError => e
        errors << [file, "#{e.class}: #{e.message}"]
      end
    end
  end

  puts [
    path.fetch("name"),
    "reader=#{path.fetch("reader")}",
    "files=#{files.length}",
    "indexed=#{indexed_files}",
    "chunks=#{chunk_count}",
    "errors=#{errors.length}",
  ].join(" | ")

  errors.first(5).each { |file, error| puts "  #{file}: #{error}" }
  summary << "## #{path.fetch("name")}"
  summary << ""
  summary << [
    "reader=`#{path.fetch("reader")}`",
    "files=#{files.length}",
    "indexed=#{indexed_files}",
    "chunks=#{chunk_count}",
    "empty_files=#{empty_files.length}",
    "errors=#{errors.length}",
  ].join(" | ")
  summary << ""
  issue_summary = issue_counts.map { |kind, count| "#{kind}=#{count}" }.join(", ")
  summary << "Potential issues: #{issue_summary.empty? ? "none" : issue_summary}"
  summary << ""

  representative_report << "## #{path.fetch("name")}"
  representative_report << ""
  samples = representative_chunks(acceptable_chunks)
  if samples.empty?
    representative_report << "No chunks passed the issue heuristics."
    representative_report << ""
  else
    samples.each do |file, chunk_index, tokens, chunk|
      representative_report << markdown_chunk(file, chunk_index, tokens, chunk)
    end
  end

  issues_report << "## #{path.fetch("name")}"
  issues_report << ""
  if errors.empty? && empty_files.empty? && issue_counts.empty?
    issues_report << "No potential issues found."
    issues_report << ""
  else
    unless errors.empty?
      issues_report << "### Reader errors (#{errors.length})"
      issues_report << ""
      errors.first(ISSUE_SAMPLES_PER_KIND).each { |file, error| issues_report << "- `#{file}`: #{error}" }
      issues_report << ""
    end

    unless empty_files.empty?
      issues_report << "### Files with no chunks (#{empty_files.length})"
      issues_report << ""
      empty_files.first(ISSUE_SAMPLES_PER_KIND).each { |file| issues_report << "- `#{file}`" }
      issues_report << ""
    end

    issue_samples.each do |kind, kind_samples|
      issues_report << "### #{kind.capitalize} (#{issue_counts.fetch(kind)})"
      issues_report << ""
      kind_samples.each do |file, chunk_index, tokens, chunk|
        note = duplicate_chunks.find { |item| item[0] == file && item[1] == chunk_index }
        issues_report << markdown_chunk(file, chunk_index, tokens, chunk, note && "matches `#{note[2]}`")
      end
    end
  end

  failed ||= errors.any?
end

File.write(File.join(output_dir, "summary.md"), summary.join("\n"))
File.write(File.join(output_dir, "representative_chunks.md"), representative_report.join("\n"))
File.write(File.join(output_dir, "potential_issues.md"), issues_report.join("\n"))

puts "Reports written to #{output_dir}"
exit 1 if failed
