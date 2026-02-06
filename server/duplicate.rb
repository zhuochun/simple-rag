require "json"
require_relative "../llm/embedding"
require_relative "../readers/reader"
require_relative "retriever" # for extract_id, extract_url, with_sqlite_store
require_relative "../storage/file_index"
require_relative "../storage/sqlite_index"

def cluster_key(cluster)
  cluster.map { |it| "#{it[:path]}/#{it[:id]}" }.sort.join('|')
end

# Find duplicate chunks across lookup paths using embedding similarity
# Returns array of clusters, each an array of items with :path, :id, :url, :text

def find_duplicates(lookup_paths, threshold = 0.9)
  items = []

  lookup_paths.each do |p|
    reader_cls = get_reader(p.reader)
    next unless reader_cls

    if p.db_file && p.db_table
      with_sqlite_store(p) do |store|
        store.each_item do |it|
          embedding = normalize_embedding(it["embedding"])
          bucket = it["bucket"] || bucket_key(embedding)
          items << {
            path: p.name,
            id: extract_id(it["path"]),
            url: extract_url(it["path"], p.url),
            source_path: it["path"],
            chunk: it["chunk"],
            reader_cls: reader_cls,
            embedding: embedding,
            bucket: bucket,
          }
        end
      end
      next
    end

    index = load_index_cache(p)
    next unless index
    index.items.each do |it|
      items << {
        path: p.name,
        id: extract_id(it[:path]),
        url: extract_url(it[:path], p.url),
        source_path: it[:path],
        chunk: it[:chunk],
        reader_cls: reader_cls,
        embedding: it[:embedding],
        bucket: it[:bucket],
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
  reader_cache = {}

  items.each_with_index do |_item, idx|
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
        next unless sim >= threshold

        visited[j] = true
        queue << j
      end
    end

    next unless cluster_indices.length > 1

    clusters << cluster_indices.map do |cidx|
      it = items[cidx]
      reader = reader_cache[it[:source_path]] ||= it[:reader_cls].new(it[:source_path]).load
      {
        path: it[:path],
        id: it[:id],
        url: it[:url],
        text: reader.get_chunk(it[:chunk])
      }
    end
  end

  clusters
end
