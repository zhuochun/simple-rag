require "digest"
require "set"

require_relative "../llm/embedding"
require_relative "../storage/sqlite_index"
require_relative "index_catalog"

module SimpleRag
  class DuplicateFinder
    VECTOR_SEARCH_K = 64
    BUCKET_CANDIDATE_LIMIT = 400

    def initialize(catalog:, locator: DocumentLocator.new)
      @catalog = catalog
      @locator = locator
    end

    def find(paths, threshold: 0.9, cross_document_only: false)
      items = deduplicate(load_items(paths))
      return [] if items.length < 2

      buckets = Hash.new { |hash, key| hash[key] = [] }
      items.each_with_index { |item, index| buckets[item[:bucket]] << index }
      adjacency, similarities = build_similarity_graph(items, buckets, threshold.to_f, cross_document_only)
      components = connected_components(adjacency)

      components.flat_map { |component| split_complete_link(component, adjacency, similarities) }
                .filter_map { |indices| build_cluster(items, indices, similarities, cross_document_only) }
    end

    private

    def load_items(paths)
      items = []
      @catalog.each_item(paths) do |path, row|
        embedding = EmbeddingMath.normalize(row["embedding"])
        items << {
          path: path.name,
          id: @locator.id(row["path"]),
          url: @locator.url(row["path"], path.url),
          source_path: row["path"],
          chunk: row["chunk"].to_i,
          hash: row["hash"],
          embedding: embedding,
          bucket: row["bucket"] || EmbeddingMath.bucket_key(embedding),
          text: row["text"]
        }
      end
      items
    end

    def deduplicate(items)
      unique = {}
      items.each do |item|
        key = [item[:source_path], item[:chunk]]
        existing = unique[key]
        if existing
          existing[:lookup_paths] |= [item[:path]]
          existing[:all_chunks] |= [item[:chunk]]
        else
          item[:lookup_paths] = [item[:path]]
          item[:all_chunks] = [item[:chunk]]
          unique[key] = item
        end
      end
      unique.values
    end

    def build_similarity_graph(items, buckets, threshold, cross_document_only)
      adjacency = Array.new(items.length) { Set.new }
      similarities = {}
      seen_pairs = Set.new
      by_path, by_path_chunk = index_maps(items)

      with_candidate_store(items) do |store|
        items.each_with_index do |item, index|
          candidate_indices(items, buckets, index, store, by_path, by_path_chunk).each do |other_index|
            left, right = index < other_index ? [index, other_index] : [other_index, index]
            next unless seen_pairs.add?([left, right])
            next if cross_document_only && item[:source_path] == items[other_index][:source_path]

            similarity = EmbeddingMath.dot_product(item[:embedding], items[other_index][:embedding])
            next if similarity < threshold

            adjacency[index] << other_index
            adjacency[other_index] << index
            similarities[[index, other_index]] = similarity
            similarities[[other_index, index]] = similarity
          end
        end
      end
      [adjacency, similarities]
    end

    def candidate_indices(items, buckets, index, store, by_path, by_path_chunk)
      candidates = Set.new(bucket_candidates(items, buckets, index))
      vector_candidates(items, index, store, by_path, by_path_chunk).each { |candidate| candidates.add(candidate) }
      candidates.delete(index)
      candidates.to_a
    end

    def bucket_candidates(items, buckets, index)
      candidates = []
      seen = Set.new
      EmbeddingMath.neighbor_keys(items[index][:bucket]).each do |key|
        Array(buckets[key]).each do |candidate|
          next if candidate == index || seen.include?(candidate)

          seen.add(candidate)
          candidates << candidate
          return candidates if candidates.length >= BUCKET_CANDIDATE_LIMIT
        end
      end
      candidates
    end

    def vector_candidates(items, index, store, by_path, by_path_chunk)
      candidates = []
      seen = Set.new
      store.vector_search(items[index][:embedding], VECTOR_SEARCH_K).each do |row|
        candidate = by_path_chunk[[row["path"], row["chunk"].to_i]]
        candidate ||= by_path[row["path"]]&.first
        next if candidate.nil? || candidate == index || seen.include?(candidate)

        seen.add(candidate)
        candidates << candidate
      end
      candidates
    end

    def index_maps(items)
      by_path = Hash.new { |hash, key| hash[key] = [] }
      by_path_chunk = {}
      items.each_with_index do |item, index|
        by_path[item[:source_path]] << index
        by_path_chunk[[item[:source_path], item[:chunk]]] = index
      end
      [by_path, by_path_chunk]
    end

    def with_candidate_store(items)
      store = SqliteIndex.new(":memory:", "duplicate_candidates")
      store.transaction do
        store.upsert_chunks(items.map do |item|
          {
            path: item[:source_path],
            chunk: item[:chunk],
            hash: item[:hash] || Digest::SHA256.hexdigest("#{item[:source_path]}##{item[:chunk]}"),
            embedding: item[:embedding],
            bucket: item[:bucket],
            text: nil
          }
        end)
      end
      yield store
    ensure
      store&.close
    end

    def connected_components(adjacency)
      components = []
      visited = Array.new(adjacency.length, false)
      adjacency.each_index do |index|
        next if visited[index] || adjacency[index].empty?

        stack = [index]
        visited[index] = true
        component = []
        until stack.empty?
          node = stack.pop
          component << node
          adjacency[node].each do |neighbor|
            next if visited[neighbor]

            visited[neighbor] = true
            stack << neighbor
          end
        end
        components << component if component.length > 1
      end
      components
    end

    def split_complete_link(component, adjacency, similarities)
      return [component] if component.length == 2

      clusters = component.map { |index| [index] }
      loop do
        best = nil
        0.upto(clusters.length - 2) do |left|
          (left + 1).upto(clusters.length - 1) do |right|
            score = merge_score(clusters[left], clusters[right], adjacency, similarities)
            next if score.nil? || (best && score <= best[:score])

            best = { left: left, right: right, score: score }
          end
        end
        break unless best

        clusters[best[:left]] += clusters[best[:right]]
        clusters.delete_at(best[:right])
      end
      clusters.select { |cluster| cluster.length > 1 }
    end

    def merge_score(left, right, adjacency, similarities)
      scores = left.product(right).map do |left_index, right_index|
        return nil unless adjacency[left_index].include?(right_index)

        similarities[[left_index, right_index]]
      end
      scores.min
    end

    def build_cluster(items, indices, similarities, cross_document_only)
      sources = indices.map { |index| items[index][:source_path] }.uniq
      return nil if cross_document_only && sources.length < 2

      cluster_items = indices.map do |index|
        item = items[index]
        pair_scores = indices.filter_map do |other_index|
          next if other_index == index

          similarities[[index, other_index]] || EmbeddingMath.dot_product(item[:embedding], items[other_index][:embedding])
        end
        {
          path: item[:path],
          id: item[:id],
          url: item[:url],
          text: item[:text],
          source_path: item[:source_path],
          chunk: item[:chunk],
          bucket: item[:bucket],
          embedding_dim: item[:embedding].length,
          lookup_paths: item[:lookup_paths],
          all_chunks: item[:all_chunks],
          max_similarity: pair_scores.max,
          avg_similarity: pair_scores.sum(0.0) / pair_scores.length
        }
      end
      { id: cluster_id(cluster_items), items: cluster_items }
    end

    def cluster_id(items)
      items.map { |item| "#{item[:source_path]}##{item[:chunk]}" }.sort.join("|")
    end

  end
end
