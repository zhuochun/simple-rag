require "json"

require_relative "sqlite_index"

class PathIndex
  attr_reader :items, :buckets, :reader_cls

  def initialize(path_config)
    @path_config = path_config
    @items = []
    @buckets = Hash.new { |h, k| h[k] = [] }
    load!
  end

  def load!
    @reader_cls = get_reader(@path_config.reader)
    return unless @reader_cls

    each_item do |item|
      emb = normalize_embedding(item["embedding"])
      idx = @items.length
      bkey = bucket_key(emb)
      @items << { embedding: emb, path: item["path"], chunk: item["chunk"], bucket: bkey }
      @buckets[bkey] << idx
    end
  end

  def each_item
    if @path_config.db_file && @path_config.db_table
      store = SqliteIndex.new(@path_config.db_file, @path_config.db_table)
      begin
        store.each_item { |item| yield item }
      ensure
        store.close
      end
      return
    end

    index_file = File.expand_path(@path_config.out)
    return unless File.exist?(index_file)

    File.foreach(index_file) do |line|
      yield JSON.parse(line)
    end
  end
end

INDEX_CACHE = {}

# Load and return PathIndex for a config path
def load_index_cache(path_config)
  INDEX_CACHE[path_config.name] ||= PathIndex.new(path_config)
end
