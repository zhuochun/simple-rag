require "fileutils"
require "time"
require "uri"

require_relative "../llm/http"

module SimpleRag
  class ArticleReader
    JINA_READER_URL = "https://r.jina.ai/".freeze
    READ_TIMEOUT = 60
    EXTRACT_PROMPT = <<~PROMPT.freeze
      Extract the core concepts, opinions and discussions from the following text.
      Organize related points into groups separated by blank lines.
      Return the result in concise markdown bullet points.
    PROMPT

    def initialize(token: nil, cache_dir: nil, chat_fn: nil, http_factory: nil, clock: nil)
      @token = token.to_s
      @cache_dir = cache_dir.to_s
      @chat_fn = chat_fn
      @http_factory = http_factory
      @clock = clock || -> { Time.now }
    end

    def fetch_and_cache(source_url)
      article = fetch(source_url)
      { article: article, cached_file: save(source_url, article) }
    end

    def list_cached
      return [] if @cache_dir.empty? || !Dir.exist?(@cache_dir)

      Dir.children(@cache_dir).filter_map do |name|
        next unless name.downcase.end_with?(".md")

        path = File.join(@cache_dir, name)
        next unless File.file?(path)

        { name: name, updated_at: File.mtime(path).utc.iso8601 }
      end.sort_by { |item| item[:updated_at] }.reverse
    end

    def read_cached(name)
      raise ArgumentError, "Cache directory is not configured" if @cache_dir.empty?
      raise ArgumentError, "Cache directory does not exist" unless Dir.exist?(@cache_dir)

      filename = File.basename(name.to_s)
      path = File.expand_path(File.join(@cache_dir, filename))
      root = File.expand_path(@cache_dir)
      unless path.start_with?("#{root}#{File::SEPARATOR}") && File.file?(path)
        raise ArgumentError, "Cache file not found"
      end

      File.read(path, encoding: "UTF-8")
    end

    def extract(text)
      raise ArgumentError, "Input text is required" if text.to_s.strip.empty?
      raise RuntimeError, "Chat provider is unavailable" unless @chat_fn

      extraction = @chat_fn.call([
        { role: "system", content: EXTRACT_PROMPT },
        { role: "user", content: text.to_s }
      ])
      {
        extraction: extraction,
        groups: extraction.to_s.strip.split(/\n\s*\n+/).map(&:strip).reject(&:empty?)
      }
    end

    private

    def fetch(source_url)
      source = validate_source_url(source_url)
      headers = {}
      headers["Authorization"] = "Bearer #{@token}" unless @token.empty?
      response = LlmHttp.get!(
        "#{JINA_READER_URL}#{source}",
        error_prefix: "Article fetch failed",
        headers: headers,
        http_factory: @http_factory,
        read_timeout: READ_TIMEOUT
      )
      response.body.to_s
    end

    def validate_source_url(source_url)
      uri = URI(source_url.to_s)
      unless %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?
        raise ArgumentError, "Article URL must use http or https and include a host"
      end

      uri.to_s
    rescue URI::InvalidURIError => error
      raise ArgumentError, "Invalid article URL: #{error.message}"
    end

    def save(source_url, article)
      return nil if @cache_dir.empty?

      FileUtils.mkdir_p(@cache_dir)
      uri = URI(source_url)
      path_slug = uri.path.gsub(/[^0-9A-Za-z]+/, "-").sub(/\A-+|\-+\z/, "")
      path_slug = "root" if path_slug.empty?
      timestamp = @clock.call.strftime("%Y-%m-%d-%H")
      filename = File.join(@cache_dir, "#{timestamp}-#{uri.host}-#{path_slug}.md")
      File.write(filename, "# URL\n#{source_url}\n\n## Original Content\n#{article}\n", encoding: "UTF-8")
      filename
    end
  end
end
