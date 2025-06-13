require "json"
require_relative "../llm/embedding"
require_relative "../readers/reader"
require_relative "retriever" # for extract_id and extract_url
require_relative "../storage/index_cache"

# Find duplicate chunks across lookup paths using embedding similarity
# Returns array of clusters, each an array of items with :path, :id, :url, :text

def find_duplicates(lookup_paths, threshold = 0.9)
  items = []

  lookup_paths.each do |p|
    index = load_index_cache(p)
    next unless index

    reader_cls = index.reader_cls
    next unless reader_cls
    file_cache = {}

    index.items.each do |it|
      reader = file_cache[it[:path]] ||= reader_cls.new(it[:path]).load
      text = reader.get_chunk(it[:chunk])
      items << {
        path: p.name,
        id: extract_id(it[:path]),
        url: extract_url(it[:path], p.url),
        embedding: it[:embedding],
        bucket: it[:bucket],
        text: text
      }
    end
  end

  # build buckets for approximate search
  buckets = Hash.new { |h, k| h[k] = [] }
  items.each_with_index do |it, i|
    buckets[it[:bucket]] << i
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
      neighbor_indices = neighbor_keys(items[i][:bucket]).flat_map { |k| buckets[k] }
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
