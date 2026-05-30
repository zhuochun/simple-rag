module QueryHelpers
  DEFAULT_BRIEF_CHARS = 220

  module_function

  def resolve_lookup_paths(config, selected, default_to_search_default: false)
    names = Array(selected).compact

    if names.empty?
      if default_to_search_default
        names = config.paths.select { |p| p.searchDefault }.map(&:name)
        names = config.path_map.keys if names.empty?
      else
        names = config.paths.map(&:name)
      end
    end

    names.map { |name| config.path_map[name] }.compact
  end

  def merge_entries_by_chunk(entries)
    unique = {}

    entries.each do |entry|
      key = [entry["path"], entry["chunk"]]
      if unique[key]
        unique[key]["score"] = (unique[key]["score"] || 0.0) + (entry["score"] || 0.0)
      else
        unique[key] = entry
      end
    end

    unique.values
  end

  def min_max_normalize_score(score, min_score, max_score)
    value = score.to_f
    if max_score > min_score
      (value - min_score) / (max_score - min_score)
    elsif value > 0
      1.0
    else
      0.0
    end
  end

  def fuse_entries_with_weighted_rrf(lists, component_weights: { weighted: 0.7, rrf: 0.3 }, rrf_k: 60)
    merged = {}

    lists.each do |list|
      entries = Array(list[:entries])
      next if entries.empty?

      list_weight = list[:weight].to_f
      ranked = entries.sort_by { |item| -(item["score"] || 0.0) }
      scores = ranked.map { |item| item["score"].to_f }
      min_score = scores.min || 0.0
      max_score = scores.max || 0.0

      ranked.each_with_index do |item, idx|
        key = [item["path"], item["chunk"]]
        row = merged[key]
        unless row
          row = item.dup
          row["_weighted_score"] = 0.0
          row["_rrf_score"] = 0.0
          merged[key] = row
        end

        normalized = min_max_normalize_score(item["score"], min_score, max_score)
        rank = idx + 1
        row["_weighted_score"] += list_weight * normalized
        row["_rrf_score"] += list_weight * (1.0 / (rrf_k + rank))
      end
    end

    rows = merged.values
    return rows if rows.empty?

    max_weighted = rows.max_by { |r| r["_weighted_score"] }["_weighted_score"].to_f
    max_rrf = rows.max_by { |r| r["_rrf_score"] }["_rrf_score"].to_f

    weighted_ratio = component_weights[:weighted].to_f
    rrf_ratio = component_weights[:rrf].to_f

    rows.each do |row|
      weighted_norm = max_weighted > 0 ? row["_weighted_score"].to_f / max_weighted : 0.0
      rrf_norm = max_rrf > 0 ? row["_rrf_score"].to_f / max_rrf : 0.0
      row["score"] = (weighted_ratio * weighted_norm) + (rrf_ratio * rrf_norm)
      row.delete("_weighted_score")
      row.delete("_rrf_score")
    end

    rows.sort_by { |item| -(item["score"] || 0.0) }
  end

  def top_n_by_score(entries, top_n)
    n = top_n.to_i
    return [] if n <= 0 || entries.empty?

    if entries.length <= n
      return entries.sort_by { |item| -(item["score"] || 0.0) }
    end

    entries.max_by(n) { |item| item["score"] || 0.0 }
           .sort_by { |item| -(item["score"] || 0.0) }
  end

  def best_entry_per_path(entries)
    best = {}

    entries.each do |item|
      path = item["path"].to_s
      next if path.empty?

      prev = best[path]
      if prev.nil? || item["score"].to_f > prev["score"].to_f
        best[path] = item
      end
    end

    best.values
  end

  def serialize_entries(entries, concise: false, brief_chars: DEFAULT_BRIEF_CHARS)
    reader_cache = {}

    entries.map do |item|
      text = nil
      if item["reader"]
        reader = reader_cache[item["path"]] ||= item["reader"].load
        text = reader.get_chunk(item["chunk"])
      end
      text = item["text"] if text.nil? || text.to_s.empty?
      text = "" if text.nil?

      row = {
        path: item["path"],
        lookup: item["lookup"],
        id: item["id"],
        url: item["url"],
        chunk: item["chunk"],
        score: item["score"],
      }

      if concise
        row[:brief] = brief_text(text, max_chars: brief_chars)
      else
        row[:text] = text
      end

      row
    end
  end

  def brief_text(text, max_chars: DEFAULT_BRIEF_CHARS)
    compact = text.to_s.gsub(/\s+/, " ").strip
    return compact if compact.length <= max_chars
    return compact if max_chars <= 3

    shortened = compact[0, max_chars - 3].to_s.rstrip
    "#{shortened}..."
  end
end
