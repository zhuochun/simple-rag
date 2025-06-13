class PathIndex
  attr_reader :items, :buckets, :reader_cls

  def initialize(path_config)
    @path_config = path_config
    @items = []
    @buckets = Hash.new { |h, k| h[k] = [] }
    load!
  end

  def load!
    index_file = File.expand_path(@path_config.out)
    return unless File.exist?(index_file)

    @reader_cls = get_reader(@path_config.reader)
    return unless @reader_cls

    File.foreach(index_file) do |line|
      item = JSON.parse(line)
      emb = normalize_embedding(item["embedding"])
      idx = @items.length
      bkey = bucket_key(emb)
      @items << { embedding: emb, path: item["path"], chunk: item["chunk"], bucket: bkey }
      @buckets[bkey] << idx
    end
  end
end

INDEX_CACHE = {}

# Load and return PathIndex for a config path
def load_index_cache(path_config)
  INDEX_CACHE[path_config.name] ||= PathIndex.new(path_config)
end
