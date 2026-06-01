module QueryHelpers
  DEFAULT_BRIEF_CHARS = 220

  module_function

  def resolve_lookup_paths(config, selected, default_to_search_default: false)
    names = Array(selected).filter_map do |name|
      value = name.to_s.strip
      value unless value.empty?
    end.uniq

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

  def top_n_by_score(entries, top_n)
    n = top_n.to_i
    return [] if n <= 0 || entries.empty?

    if entries.length <= n
      return entries.sort_by { |item| -sort_score(item) }
    end

    entries.max_by(n) { |item| sort_score(item) }
           .sort_by { |item| -sort_score(item) }
  end

  def serialize_entries(entries, concise: false, brief_chars: DEFAULT_BRIEF_CHARS)
    entries.map do |item|
      text = item["text"].to_s

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

  def compact_file_results(files, brief_chars: DEFAULT_BRIEF_CHARS)
    Array(files).map do |file|
      anchor = file[:anchor_chunk] || {}
      {
        path: file[:path],
        score: file[:score].to_f.round(4),
        chunk: anchor[:chunk],
        text: brief_text(anchor[:text], max_chars: brief_chars),
      }
    end
  end

  def brief_text(text, max_chars: DEFAULT_BRIEF_CHARS)
    compact = text.to_s.gsub(/\s+/, " ").strip
    return compact if compact.length <= max_chars
    return compact if max_chars <= 3

    shortened = compact[0, max_chars - 3].to_s.rstrip
    "#{shortened}..."
  end

  def sort_score(item)
    item.fetch("_sort_score", item["score"] || 0.0).to_f
  end
end
