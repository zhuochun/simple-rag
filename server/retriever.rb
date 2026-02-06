require "pathname"
require "json"

require_relative "cache"
require_relative "../llm/llm"
require_relative "../llm/embedding"
require_relative "../readers/reader"
require_relative "../storage/file_index"
require_relative "../storage/sqlite_index"

AGENT_PROMPT = <<~PROMPT
You rewrite a user query for semantic search over markdown documents.

Rules:
- Keep the same intent.
- Use clear, plain words.
- Add useful context terms from the user text (topic, entity, version, time).
- Do not answer the question.
- Output exactly one line, no quotes, no labels, no extra text.
PROMPT

VECTOR_SEARCH_K = 512

def expand_query(q)
    msgs = [
        { role: ROLE_SYSTEM, content: AGENT_PROMPT },
        { role: ROLE_USER, content: q },
    ]

    query = chat(msgs).strip
    STDOUT << "Expand query: #{query}\n"

    query
end

def with_sqlite_store(path_config, store_cache = nil)
    if store_cache
        key = [path_config.db_file, path_config.db_table]
        store = store_cache[key]
        unless store
            store = SqliteIndex.new(path_config.db_file, path_config.db_table)
            store_cache[key] = store
        end
        return yield(store)
    end

    store = SqliteIndex.new(path_config.db_file, path_config.db_table)
    begin
        yield(store)
    ensure
        store.close
    end
end

def close_store_cache(store_cache)
    return unless store_cache

    store_cache.each_value do |store|
        begin
            store.close
        rescue
            # ignore close errors
        end
    end
    store_cache.clear
end

def normalize_search_terms(query_or_queries)
    Array(query_or_queries).flatten.map(&:to_s).map(&:strip).reject(&:empty?).uniq
end

def retrieve_by_embedding(lookup_paths, q, store_cache: nil)
    begin
        qe = CACHE.get_or_set(q, method(:embedding).to_proc)
        qn = normalize_embedding(qe)
    rescue => e
        STDOUT << "Embedding retrieval skipped: #{e.class}: #{e.message}\n"
        return []
    end

    entries = []
    lookup_paths.each do |p|
        STDOUT << "Reading index: #{p.name}\n"
        reader_cls = get_reader(p.reader)
        next if reader_cls.nil?

        if p.db_file && p.db_table
            with_sqlite_store(p, store_cache) do |store|
                file_cache = {}
                matched_candidates = 0

                store.vector_search(qn, VECTOR_SEARCH_K).each do |item|
                    matched_candidates += 1
                    score = dot_product(qn, normalize_embedding(item["embedding"]))
                    next if score < p.threshold

                    entries << {
                        "path" => item["path"],
                        "chunk" => item["chunk"],
                        "score" => score,
                        "lookup" => p.name,
                        "id" => extract_id(item["path"]),
                        "url" => extract_url(item["path"], p.url),
                        "reader" => (file_cache[item["path"]] ||= reader_cls.new(item["path"]))
                    }
                end

                # Fallback path when vector extension/index is unavailable.
                if matched_candidates.zero?
                    neighbor_buckets = neighbor_keys(bucket_key(qn)).uniq
                    store.each_item_by_buckets(neighbor_buckets) do |item|
                        matched_candidates += 1
                        score = dot_product(qn, normalize_embedding(item["embedding"]))
                        next if score < p.threshold

                        entries << {
                            "path" => item["path"],
                            "chunk" => item["chunk"],
                            "score" => score,
                            "lookup" => p.name,
                            "id" => extract_id(item["path"]),
                            "url" => extract_url(item["path"], p.url),
                            "reader" => (file_cache[item["path"]] ||= reader_cls.new(item["path"]))
                        }
                    end

                    # Backward compatibility for legacy rows that do not have bucket populated.
                    if matched_candidates.zero?
                        store.each_item_without_bucket do |item|
                            score = dot_product(qn, normalize_embedding(item["embedding"]))
                            next if score < p.threshold

                            entries << {
                                "path" => item["path"],
                                "chunk" => item["chunk"],
                                "score" => score,
                                "lookup" => p.name,
                                "id" => extract_id(item["path"]),
                                "url" => extract_url(item["path"], p.url),
                                "reader" => (file_cache[item["path"]] ||= reader_cls.new(item["path"]))
                            }
                        end
                    end
                end
            end
        else
            index = load_index_cache(p)
            next unless index

            file_cache = {}
            bucket_ids = neighbor_keys(bucket_key(qn)).flat_map { |k| index.buckets[k] }.uniq
            bucket_ids.each do |idx|
                item = index.items[idx]

                score = dot_product(qn, item[:embedding])
                next if score < p.threshold

                entries << {
                    "path" => item[:path],
                    "chunk" => item[:chunk],
                    "score" => score,
                    "lookup" => p.name,
                    "id" => extract_id(item[:path]),
                    "url" => extract_url(item[:path], p.url),
                    "reader" => (file_cache[item[:path]] ||= reader_cls.new(item[:path]))
                }
            end
        end

        STDOUT << "Matched num: #{entries.length}\n"
    end

    entries
end

def extract_id(file_path)
    path = Pathname.new(file_path)
    File.join(path.each_filename.to_a[-2..-1])
end

def extract_url(file_path, url)
    if url
        path = Pathname.new(file_path)
        # Extract the filename without the extension
        filename_without_extension = path.basename(path.extname).to_s
        # Return the final URL
        "#{url}#{filename_without_extension}"
    else
        "file://#{file_path}"
    end
end

VARIANT_PROMPT = <<~PROMPT
Generate 3 short search variants for exact keyword matching in markdown.

Rules:
- Keep the same intent as the user input.
- Each variant should be 1 to 5 words.
- Prefer concrete nouns, names, acronyms, and likely terms from docs.
- Variants must be different from each other.
- Output one CSV line only: term1, term2, term3
- No numbering, no bullets, no quotes, no extra text.
PROMPT

def expand_variants(q)
    msgs = [
        { role: ROLE_SYSTEM, content: VARIANT_PROMPT },
        { role: ROLE_USER, content: q },
    ]

    variants = chat(msgs).split(',').map(&:strip).reject(&:empty?).uniq
    STDOUT << "Expand variants: #{variants}\n"
    variants
end

def retrieve_by_text(lookup_paths, query_or_queries, store_cache: nil)
    queries = normalize_search_terms(query_or_queries)
    return [] if queries.empty?

    entries = []
    lookup_paths.each do |p|
        STDOUT << "Reading text index: #{p.name}\n"

        reader_cls = get_reader(p.reader)
        next if reader_cls.nil?

        file_cache = {}
        if p.db_file && p.db_table
            with_sqlite_store(p, store_cache) do |store|
                store.text_search_any(queries).each do |item|
                    reader = file_cache[item["path"]] ||= reader_cls.new(item["path"])
                    if item["text"].nil?
                        text = reader.load.get_chunk(item["chunk"])
                        next unless text && queries.any? { |q| text.include?(q) }
                    end

                    item["score"] = 1.0
                    item["lookup"] = p.name
                    item["id"] = extract_id(item["path"])
                    item["url"] = extract_url(item["path"], p.url)
                    item["reader"] = reader

                    entries << item
                end
            end
            STDOUT << "Matched num: #{entries.length}\n"
            next
        end

        index_file = File.expand_path(p.out)
        next unless File.exist?(index_file)

        File.foreach(index_file) do |line|
            item = JSON.parse(line)
            reader = file_cache[item["path"]] ||= reader_cls.new(item["path"]).load
            chunk_text = reader.get_chunk(item["chunk"])
            next unless chunk_text && queries.any? { |q| chunk_text.include?(q) }

            item["score"] = 1.0
            item["lookup"] = p.name
            item["id"] = extract_id(item["path"])
            item["url"] = extract_url(item["path"], p.url)
            item["reader"] = reader

            entries << item
        end

        STDOUT << "Matched num: #{entries.length}\n"
    end

    entries
end
