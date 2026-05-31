require "json"
require "set"
require_relative "../llm/embedding"
require_relative "retriever" # for extract_id, extract_url, with_sqlite_store
require_relative "../storage/sqlite_index"

DUP_VECTOR_SEARCH_K = 64
DUP_BUCKET_CANDIDATE_LIMIT = 400

def cluster_key(cluster)
  cluster.map { |it| "#{it[:source_path]}##{it[:chunk]}" }.sort.join('|')
end

# Find duplicate chunks across lookup paths using embedding similarity
# Returns array of clusters, each an array of duplicate items.

def pre_dedup_duplicate_items(items)
  dedup = {}
  items.each do |it|
    key = [it[:source_path], it[:chunk]]
    existing = dedup[key]
    if existing
      existing[:lookup_paths] |= [it[:path]]
      existing[:all_chunks] |= [it[:chunk]]
      next
    end

    it[:lookup_paths] = [it[:path]]
    it[:all_chunks] = [it[:chunk]]
    dedup[key] = it
  end

  dedup.values
end

def collect_bucket_candidates(items, buckets, idx, limit = DUP_BUCKET_CANDIDATE_LIMIT)
  item = items[idx]
  candidates = []
  seen = Set.new

  neighbor_keys(item[:bucket]).each do |key|
    bucket = buckets[key]
    next if bucket.nil? || bucket.empty?

    bucket.each do |j|
      next if j == idx || seen.include?(j)
      seen.add(j)
      candidates << j
      return candidates if candidates.length >= limit
    end
  end

  candidates
end

def build_index_maps(items)
  by_source_path = Hash.new { |h, k| h[k] = [] }
  by_source_path_chunk = {}

  items.each_with_index do |item, idx|
    by_source_path[item[:source_path]] << idx
    by_source_path_chunk[[item[:source_path], item[:chunk]]] = idx
  end

  [by_source_path, by_source_path_chunk]
end

def collect_sqlite_vector_candidates(items, idx, store, by_source_path, by_source_path_chunk)
  item = items[idx]
  results = store.vector_search(item[:embedding], DUP_VECTOR_SEARCH_K)
  return [] if results.empty?

  candidates = []
  seen = Set.new
  results.each do |row|
    r_path = row["path"]
    r_chunk = row["chunk"].to_i
    candidate_idx = by_source_path_chunk[[r_path, r_chunk]]
    candidate_idx ||= by_source_path[r_path]&.first
    next if candidate_idx.nil? || candidate_idx == idx || seen.include?(candidate_idx)
    seen.add(candidate_idx)
    candidates << candidate_idx
  end
  candidates
end

def with_duplicate_candidate_store(items)
  store = SqliteIndex.new(":memory:", "duplicate_candidates")
  store.transaction do
    items.each do |item|
      store.upsert_chunk(
        path: item[:source_path],
        chunk: item[:chunk],
        hash: item[:hash],
        embedding: item[:embedding],
        bucket: item[:bucket],
        text: nil
      )
    end
  end

  yield(store)
ensure
  store&.close
end

def candidate_indices_for_item(items, buckets, idx, candidate_store, by_source_path, by_source_path_chunk)
  candidates = Set.new(collect_bucket_candidates(items, buckets, idx))
  collect_sqlite_vector_candidates(items, idx, candidate_store, by_source_path, by_source_path_chunk).each do |candidate_idx|
    candidates.add(candidate_idx)
  end

  candidates.delete(idx)
  candidates.to_a
end

def build_similarity_graph(items, buckets, threshold, cross_document_only)
  adjacency = Array.new(items.length) { Set.new }
  sim_cache = {}
  pair_seen = Set.new
  by_source_path, by_source_path_chunk = build_index_maps(items)

  with_duplicate_candidate_store(items) do |candidate_store|
    items.each_with_index do |item, i|
      neighbor_indices = candidate_indices_for_item(items, buckets, i, candidate_store, by_source_path, by_source_path_chunk)
      neighbor_indices.each do |j|
        a, b = i < j ? [i, j] : [j, i]
        next if a == b
        next if pair_seen.include?([a, b])
        pair_seen.add([a, b])
        next if cross_document_only && item[:source_path] == items[j][:source_path]

        sim = dot_product(item[:embedding], items[j][:embedding])
        next unless sim >= threshold

        adjacency[i] << j
        adjacency[j] << i
        sim_cache[[i, j]] = sim
        sim_cache[[j, i]] = sim
      end
    end
  end

  [adjacency, sim_cache]
end

def connected_components(adjacency)
  components = []
  visited = Array.new(adjacency.length, false)

  adjacency.each_index do |idx|
    next if visited[idx]
    next if adjacency[idx].empty?

    stack = [idx]
    visited[idx] = true
    component = []

    until stack.empty?
      node = stack.pop
      component << node
      adjacency[node].each do |nbr|
        next if visited[nbr]
        visited[nbr] = true
        stack << nbr
      end
    end

    components << component if component.length > 1
  end

  components
end

def cluster_merge_score(left, right, adjacency, sim_cache)
  min_sim = nil

  left.each do |i|
    right.each do |j|
      return nil unless adjacency[i].include?(j)

      sim = sim_cache[[i, j]]
      min_sim = sim if min_sim.nil? || sim < min_sim
    end
  end

  min_sim
end

def split_component_complete_link(component, adjacency, sim_cache)
  return [component] if component.length == 2

  if component.length == 3
    a, b, c = component
    ab = adjacency[a].include?(b)
    ac = adjacency[a].include?(c)
    bc = adjacency[b].include?(c)
    return [component] if ab && ac && bc

    pairs = []
    pairs << [[a, b], sim_cache[[a, b]]] if ab
    pairs << [[a, c], sim_cache[[a, c]]] if ac
    pairs << [[b, c], sim_cache[[b, c]]] if bc
    return [] if pairs.empty?
    best_pair = pairs.max_by { |(_pair, sim)| sim.to_f }
    return [best_pair[0]]
  end

  clusters = component.map { |idx| [idx] }

  loop do
    best_left = nil
    best_right = nil
    best_score = nil

    0.upto(clusters.length - 2) do |li|
      (li + 1).upto(clusters.length - 1) do |ri|
        score = cluster_merge_score(clusters[li], clusters[ri], adjacency, sim_cache)
        next if score.nil?
        next if !best_score.nil? && score <= best_score

        best_left = li
        best_right = ri
        best_score = score
      end
    end

    break if best_left.nil?

    clusters[best_left] = clusters[best_left] + clusters[best_right]
    clusters.delete_at(best_right)
  end

  clusters.select { |c| c.length > 1 }
end

def find_duplicates(lookup_paths, threshold = 0.9, cross_document_only: false)
  items = []

  lookup_paths.each do |p|
    with_sqlite_store(p) do |store|
      store.each_item do |it|
        embedding = normalize_embedding(it["embedding"])
        bucket = it["bucket"] || bucket_key(embedding)
        items << {
          path: p.name,
          id: extract_id(it["path"]),
          url: extract_url(it["path"], p.url),
          source_path: it["path"],
          chunk: it["chunk"].to_i,
          hash: it["hash"],
          embedding: embedding,
          bucket: bucket,
          text: it["text"],
        }
      end
    end
  end

  items = pre_dedup_duplicate_items(items)
  return [] if items.length < 2

  # build buckets for approximate search
  buckets = Hash.new { |h, k| h[k] = [] }
  items.each_with_index do |it, i|
    buckets[it[:bucket]] << i
  end

  adjacency, sim_cache = build_similarity_graph(items, buckets, threshold, cross_document_only)
  components = connected_components(adjacency)

  cluster_indices_list = components.flat_map do |component|
    split_component_complete_link(component, adjacency, sim_cache)
  end

  clusters = []
  cluster_indices_list.each do |cluster_indices|
    if cross_document_only
      unique_sources = cluster_indices.map { |cidx| items[cidx][:source_path] }.uniq
      next unless unique_sources.length > 1
    end

    clusters << cluster_indices.map do |cidx|
      it = items[cidx]
      pair_sims = cluster_indices.filter_map do |oidx|
        next if oidx == cidx
        sim_cache[[cidx, oidx]] || dot_product(items[cidx][:embedding], items[oidx][:embedding])
      end

      {
        path: it[:path],
        id: it[:id],
        url: it[:url],
        text: it[:text],
        source_path: it[:source_path],
        chunk: it[:chunk],
        bucket: it[:bucket],
        embedding_dim: it[:embedding].length,
        lookup_paths: it[:lookup_paths],
        all_chunks: it[:all_chunks],
        max_similarity: pair_sims.max,
        avg_similarity: pair_sims.empty? ? nil : (pair_sims.sum(0.0) / pair_sims.length),
      }
    end
  end

  clusters
end
