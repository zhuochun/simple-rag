require "pathname"

require_relative "../lib/query_helpers"

module SimpleRag
  class ServerRuntime
    class BadRequest < StandardError; end
    class NotFound < StandardError; end
    class UpstreamError < StandardError; end

    def initialize(
      config_file:,
      config_digest:,
      config:,
      retriever:,
      similarity_retriever:,
      duplicate_finder:,
      catalog:,
      locator:,
      dismissals:,
      article_reader:,
      discuss_fn:
    )
      @config_file = config_file
      @config_digest = config_digest
      @config = config
      @retriever = retriever
      @similarity_retriever = similarity_retriever
      @duplicate_finder = duplicate_finder
      @catalog = catalog
      @locator = locator
      @dismissals = dismissals
      @article_reader = article_reader
      @discuss_fn = discuss_fn
    end

    def health
      { status: "ok", config: @config_file, configDigest: @config_digest }
    end

    def paths
      @config.paths.map { |path| { name: path.name, searchDefault: !!path.searchDefault } }
    end

    def map_data
      path = map_data_path
      raise NotFound, "Map data not found. Run run-index-map-v2 first. expected=#{path}" unless File.file?(path)

      File.read(path, encoding: "UTF-8")
    end

    def map_note(data)
      path_config = @config.path_map[data["lookup"].to_s]
      raise NotFound, "Map note not found in configured index" unless path_config

      chunk = integer(data["chunk"], "chunk")
      row = @catalog.find_chunk(path_config, data["path"].to_s, chunk, hash: data["hash"])
      raise NotFound, "Map note not found in configured index" unless row
      raise NotFound, "Map note chunk is empty" if row["text"].to_s.strip.empty?

      {
        path: row["path"],
        lookup: path_config.name,
        id: @locator.id(row["path"]),
        url: @locator.url(row["path"], path_config.url),
        chunk: row["chunk"],
        text: row["text"]
      }
    end

    def query(data, expanded: false)
      lookup_paths = resolve_paths(data["paths"], default_to_search_default: true)
      top_n = top_n(data["topN"], default: 20)
      if expanded
        @retriever.retrieve_q_plus(lookup_paths, data["q"], top_n: top_n)
      else
        @retriever.retrieve_q(lookup_paths, data["q"], top_n: top_n)
      end
    end

    def discuss(data)
      note = data["note"].to_s
      raise BadRequest, "note is required" if note.strip.empty?

      { discussion: @discuss_fn.call(note, data["query"]) }
    rescue BadRequest
      raise
    rescue => error
      raise UpstreamError, "Failed to discuss note: #{error.message}"
    end

    def duplicates(data)
      threshold = float(data.fetch("threshold", 0.9), "threshold")
      raise BadRequest, "threshold must be between -1 and 1" unless threshold.between?(-1.0, 1.0)

      clusters = @duplicate_finder.find(
        resolve_paths(data["paths"]),
        threshold: threshold,
        cross_document_only: data.key?("cross_document_only") ? !!data["cross_document_only"] : true
      )
      { clusters: clusters.reject { |cluster| @dismissals.include?(cluster[:id]) } }
    end

    def dismiss(data)
      id = data["id"].to_s.strip
      raise BadRequest, "id is required" if id.empty?

      { ok: true, changed: @dismissals.dismiss(id) }
    end

    def random(data)
      count = integer(data.fetch("count", 3), "count")
      raise BadRequest, "count must be between 1 and 100" unless count.between?(1, 100)

      { data: @catalog.random(resolve_paths(data["paths"]), count) }
    end

    def similar(data)
      paths = resolve_paths(data["paths"])
      count = top_n(data["topN"], default: 3)
      note = data["note"]
      entries = @similarity_retriever.retrieve(paths, note, top_n: count)
      { data: QueryHelpers.serialize_entries(entries) }
    end

    def cached_articles
      { data: @article_reader.list_cached }
    end

    def cached_article(data)
      { content: @article_reader.read_cached(data["name"]) }
    rescue ArgumentError => error
      raise BadRequest, error.message
    end

    def fetch_article(data)
      @article_reader.fetch_and_cache(data["url"].to_s)
    rescue ArgumentError => error
      raise BadRequest, error.message
    rescue => error
      raise UpstreamError, error.message
    end

    def extract_notes(data)
      @article_reader.extract(data["text"].to_s)
    rescue ArgumentError => error
      raise BadRequest, error.message
    rescue => error
      raise UpstreamError, error.message
    end

    def close
      @retriever.close
    ensure
      @catalog.close
    end

    private

    def resolve_paths(selected, default_to_search_default: false)
      paths = QueryHelpers.resolve_lookup_paths(
        @config,
        selected,
        default_to_search_default: default_to_search_default
      )
      raise BadRequest, "No lookup paths selected" if paths.empty?

      paths
    end

    def top_n(raw, default:)
      value = raw.nil? ? default : integer(raw, "topN")
      unless value.between?(1, QueryHelpers::MAX_TOP_N)
        raise BadRequest, "topN must be between 1 and #{QueryHelpers::MAX_TOP_N}"
      end

      value
    end

    def integer(raw, name)
      Integer(raw)
    rescue ArgumentError, TypeError
      raise BadRequest, "#{name} must be an integer"
    end

    def float(raw, name)
      Float(raw)
    rescue ArgumentError, TypeError
      raise BadRequest, "#{name} must be numeric"
    end

    def map_data_path
      map = @config.respond_to?(:map) ? @config.map : nil
      configured = if map.respond_to?(:path)
        map.path
      elsif map.is_a?(Hash)
        map["path"] || map[:path]
      end.to_s.strip
      raise BadRequest, %(Config field "map.path" is required for map endpoints) if configured.empty?

      path = Pathname.new(configured)
      path.absolute? ? path.to_s : File.expand_path(configured, File.dirname(@config_file))
    end
  end
end
