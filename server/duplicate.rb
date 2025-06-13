require "json"
require_relative "../llm/embedding"
require_relative "../readers/reader"
require_relative "retriever" # for extract_id and extract_url

# Find duplicate chunks across lookup paths using embedding similarity
# Returns array of clusters, each an array of items with :path, :id, :url, :text

def find_duplicates(lookup_paths, threshold = 0.9)
  items = []

  lookup_paths.each do |p|
    index_file = File.expand_path(p.out)
    next unless File.exist?(index_file)

    reader_cls = get_reader(p.reader)
    next unless reader_cls
    file_cache = {}

    File.foreach(index_file) do |line|
      item = JSON.parse(line)
      reader = file_cache[item["path"]] ||= reader_cls.new(item["path"]).load
      text = reader.get_chunk(item["chunk"])
      items << {
        path: p.name,
        id: extract_id(item["path"]),
        url: extract_url(item["path"], p.url),
        embedding: item["embedding"],
        text: text
      }
    end
  end

  # normalize embeddings and build buckets for approximate search
  buckets = Hash.new { |h, k| h[k] = [] }
  items.each_with_index do |it, i|
    it[:embedding] = normalize_embedding(it[:embedding])
    key = bucket_key(it[:embedding])
    buckets[key] << i
  end

  clusters = []
  visited = Array.new(items.length, false)

  items.each_with_index do |item, idx|
    next if visited[idx]
    cluster_indices = []
    queue = [idx]
    visited[idx] = true

    until queue.empty?
      i = queue.pop
      cluster_indices << i
      neighbor_indices = neighbor_keys(bucket_key(items[i][:embedding])).flat_map { |k| buckets[k] }
      neighbor_indices.each do |j|
        next if visited[j] || j == i
        sim = dot_product(items[i][:embedding], items[j][:embedding])
        if sim >= threshold
          visited[j] = true
          queue << j
        end
      end
    end

    if cluster_indices.length > 1
      clusters << cluster_indices.map do |cidx|
        it = items[cidx]
        {
          path: it[:path],
          id: it[:id],
          url: it[:url],
          text: it[:text]
        }
      end
    end
  end

  clusters
end
