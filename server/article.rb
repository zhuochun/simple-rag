require 'net/http'
require 'uri'
require 'time'
require_relative '../llm/llm'

JINA_READER_API = 'https://r.jina.ai/'

EXTRACT_PROMPT = <<~PROMPT
Extract the core concepts, opinions and discussions from the following text.
Organize related points into groups separated by blank lines.
Return the result in concise markdown bullet points.
PROMPT

# Fetch article markdown using Jina Reader
# url: string
# Returns markdown text

def fetch_article(url)
  uri = URI("#{JINA_READER_API}#{url}")
  request = Net::HTTP::Get.new(uri)
  token = cfg(:jina, 'token', '')
  request['Authorization'] = "Bearer #{token}" unless token.to_s.empty?

  Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    response = http.request(request)
    response.body
  end
end

def cache_dir
  cfg(:jina, 'cacheDir', '')
end

# Return cached markdown files sorted by mtime descending.
def list_cached_articles
  dir = cache_dir.to_s
  return [] if dir.strip.empty? || !Dir.exist?(dir)

  Dir.children(dir)
     .select { |name| name.downcase.end_with?('.md') }
     .map do |name|
       path = File.join(dir, name)
       next unless File.file?(path)

       {
         name: name,
         updated_at: File.mtime(path).utc.iso8601,
       }
     end
     .compact
     .sort_by { |item| item[:updated_at] }
     .reverse
end

# Read a single cached article file.
def read_cached_article(name)
  dir = cache_dir.to_s
  raise ArgumentError, 'Cache directory is not configured' if dir.strip.empty?
  raise ArgumentError, 'Cache directory does not exist' unless Dir.exist?(dir)

  fname = File.basename(name.to_s)
  path = File.expand_path(File.join(dir, fname))
  root = File.expand_path(dir)
  unless path == root || path.start_with?("#{root}#{File::SEPARATOR}")
    raise ArgumentError, 'Invalid cache file path'
  end
  raise ArgumentError, 'Cache file not found' unless File.file?(path)

  File.read(path)
end

# Save article URL and analysis to cache markdown file
# url: the original URL
# article: fetched markdown text
# extraction: extracted bullet points
# argument: new content bullet points
def save_article_result(url, article, extraction, argument)
  dir = cache_dir.to_s
  return if dir.to_s.strip.empty?

  require 'fileutils'
  FileUtils.mkdir_p(dir)

  host = 'unknown'
  path = 'content'
  begin
    uri = URI.parse(url)
    host = uri.host || host
    path = uri.path.gsub(%r{[^0-9A-Za-z]+}, '-')
    path = 'root' if path.empty?
  rescue
    # ignore malformed urls
  end

  ts = Time.now.strftime('%Y-%m-%d-%H')
  fname = File.join(dir, "#{ts}-#{host}-#{path}.md")

  File.open(fname, 'w') do |f|
    f.puts "# URL"
    f.puts url
    f.puts
    f.puts "## Original Content"
    f.puts article
    f.puts
    f.puts "## Extraction"
    f.puts extraction
    f.puts
    f.puts "## New Content"
    f.puts argument
  end

  fname
rescue StandardError => e
  warn "Failed to save article result: #{e.message}"
  nil
end

# Extract core concepts from article markdown
# text: markdown text
# Returns concise markdown bullet points

def extract_article(text)
  msgs = [
    { role: ROLE_SYSTEM, content: EXTRACT_PROMPT },
    { role: ROLE_USER, content: text }
  ]
  chat(msgs)
end

# Split the extracted text into thematic groups separated by blank lines.
# extraction: string returned from +extract_article+
# Returns an array of strings, one per group.
def split_extraction_groups(extraction)
  extraction.to_s.strip.split(/\n\s*\n+/).map(&:strip).reject(&:empty?)
end

