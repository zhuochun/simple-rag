require "json"

class FileIndex
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
    out_path = @path_config.out
    return if out_path.nil? || out_path.to_s.strip.empty?

    index_file = File.expand_path(out_path)
    return unless File.exist?(index_file)

    File.foreach(index_file) do |line|
      yield JSON.parse(line)
    end
  end
end

INDEX_CACHE = {}

# Load and return FileIndex for a config path
def load_index_cache(path_config)
  INDEX_CACHE[path_config.name] ||= FileIndex.new(path_config)
end
