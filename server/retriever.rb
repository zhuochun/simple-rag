require "pathname"
require "json"
require "etc"
require "thread"

require_relative "cache"
require_relative "../llm/llm"
require_relative "../llm/embedding"
require_relative "../readers/reader"
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
VECTOR_SEARCH_K_MIN = 64
VECTOR_SEARCH_K_MULTIPLIER = 12
TEXT_SEARCH_LIMIT_MAX = 800
TEXT_SEARCH_LIMIT_MULTIPLIER = 20
RETRIEVE_THREADS_MAX = 8
STORE_CACHE_MUTEX = Mutex.new
RETRIEVE_PROGRESS_LOG = ENV["RAG_RETRIEVE_PROGRESS"].to_s == "1"

def retrieve_progress(message)
    return unless RETRIEVE_PROGRESS_LOG

    STDOUT << message
end

def expand_query(q)
    msgs = [
        { role: ROLE_SYSTEM, content: AGENT_PROMPT },
        { role: ROLE_USER, content: q },
    ]

    query = chat(msgs).strip
    retrieve_progress("Expand query: #{query}\n")

    query
end

def with_sqlite_store(path_config, store_cache = nil)
    if store_cache
        key = [path_config.db_file, path_config.db_table]
        store = nil
        STORE_CACHE_MUTEX.synchronize do
            store = store_cache[key]
            unless store
                store = SqliteIndex.new(path_config.db_file, path_config.db_table)
                store_cache[key] = store
            end
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

def retrieve_worker_count(path_count)
    return 1 if path_count.to_i <= 1

    env_threads = ENV["RAG_RETRIEVE_THREADS"].to_i
    if env_threads > 0
        return [[env_threads, RETRIEVE_THREADS_MAX].min, path_count.to_i].min
    end

    cpu = Etc.respond_to?(:nprocessors) ? Etc.nprocessors.to_i : 4
    cpu = 4 if cpu <= 0
    [[cpu, RETRIEVE_THREADS_MAX].min, path_count.to_i].min
end

def each_lookup_path(lookup_paths, parallel: true)
    paths = Array(lookup_paths).compact
    return if paths.empty?

    if !parallel || paths.length <= 1
        paths.each { |p| yield(p) }
        return
    end

    queue = Queue.new
    paths.each { |p| queue << p }

    workers = retrieve_worker_count(paths.length)
    threads = workers.times.map do
        Thread.new do
            loop do
                path = begin
                    queue.pop(true)
                rescue ThreadError
                    nil
                end
                break if path.nil?
                yield(path)
            rescue => e
                STDOUT << "Path retrieval failed (#{path&.name || "unknown"}): #{e.class}: #{e.message}\n"
            end
        end
    end
    threads.each(&:join)
end

def vector_search_k_for_top_n(top_n)
    n = top_n.to_i
    return VECTOR_SEARCH_K if n <= 0

    [[n * VECTOR_SEARCH_K_MULTIPLIER, VECTOR_SEARCH_K_MIN].max, VECTOR_SEARCH_K].min
end

def text_limit_for_top_n(top_n)
    n = top_n.to_i
    return nil if n <= 0

    [n * TEXT_SEARCH_LIMIT_MULTIPLIER, TEXT_SEARCH_LIMIT_MAX].min
end

def retrieve_by_embedding(lookup_paths, q, store_cache: nil, top_n: nil, parallel: true, use_cache: true)
    begin
        qe = if use_cache
            CACHE.get_or_set(q, method(:embedding).to_proc)
        else
            embedding(q)
        end
        qn = normalize_embedding(qe)
    rescue => e
        STDOUT << "Embedding retrieval skipped: #{e.class}: #{e.message}\n"
        return []
    end

    k = vector_search_k_for_top_n(top_n)
    entries = []
    entries_mutex = Mutex.new

    each_lookup_path(lookup_paths, parallel: parallel) do |p|
        retrieve_progress("Reading index: #{p.name}\n")
        reader_cls = get_reader(p.reader)
        next if reader_cls.nil?

        path_entries = []
        with_sqlite_store(p, store_cache) do |store|
            file_cache = {}
            matched_candidates = 0

            store.vector_search(qn, k).each do |item|
                matched_candidates += 1
                score = dot_product(qn, normalize_embedding(item["embedding"]))
                next if score < p.threshold

                path_entries << {
                    "path" => item["path"],
                    "chunk" => item["chunk"],
                    "score" => score,
                    "lookup" => p.name,
                    "id" => extract_id(item["path"]),
                    "url" => extract_url(item["path"], p.url),
                    "text" => item["text"],
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

                    path_entries << {
                        "path" => item["path"],
                        "chunk" => item["chunk"],
                        "score" => score,
                        "lookup" => p.name,
                        "id" => extract_id(item["path"]),
                        "url" => extract_url(item["path"], p.url),
                        "text" => item["text"],
                        "reader" => (file_cache[item["path"]] ||= reader_cls.new(item["path"]))
                    }
                end

                # Backward compatibility for legacy rows that do not have bucket populated.
                if matched_candidates.zero?
                    store.each_item_without_bucket do |item|
                        score = dot_product(qn, normalize_embedding(item["embedding"]))
                        next if score < p.threshold

                        path_entries << {
                            "path" => item["path"],
                            "chunk" => item["chunk"],
                            "score" => score,
                            "lookup" => p.name,
                            "id" => extract_id(item["path"]),
                            "url" => extract_url(item["path"], p.url),
                            "text" => item["text"],
                            "reader" => (file_cache[item["path"]] ||= reader_cls.new(item["path"]))
                        }
                    end
                end
            end
        end

        entries_mutex.synchronize { entries.concat(path_entries) }
        retrieve_progress("Matched num for #{p.name}: #{path_entries.length}\n")
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
Generate 6 short keyword variants for exact keyword matching in markdown.

Rules:
- Keep the same intent as the user input.
- Output exactly 6 terms:
  - 3 Chinese terms, each 1 to 6 characters.
  - 3 English terms, each 1 to 3 words.
- Prefer concrete nouns, names, acronyms, and likely terms from docs.
- Terms must be distinct and useful for search.
- Output one CSV line only in this order:
  zh_term1, zh_term2, zh_term3, en_term1, en_term2, en_term3
- No numbering, no bullets, no quotes, no extra text.
PROMPT

def expand_variants(q)
    msgs = [
        { role: ROLE_SYSTEM, content: VARIANT_PROMPT },
        { role: ROLE_USER, content: q },
    ]

    variants = chat(msgs).split(',').map(&:strip).reject(&:empty?).uniq.first(6)
    retrieve_progress("Expand variants: #{variants}\n")
    variants
end

def retrieve_by_text(lookup_paths, query_or_queries, store_cache: nil, top_n: nil, parallel: true)
    queries = normalize_search_terms(query_or_queries)
    return [] if queries.empty?

    limit_per_path = text_limit_for_top_n(top_n)
    entries = []
    entries_mutex = Mutex.new

    each_lookup_path(lookup_paths, parallel: parallel) do |p|
        retrieve_progress("Reading text index: #{p.name}\n")

        reader_cls = get_reader(p.reader)
        next if reader_cls.nil?

        file_cache = {}
        path_entries = []
        with_sqlite_store(p, store_cache) do |store|
            store.text_search_any(queries, limit: limit_per_path).each do |item|
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

                path_entries << item
            end
        end

        entries_mutex.synchronize { entries.concat(path_entries) }
        retrieve_progress("Matched num for #{p.name}: #{path_entries.length}\n")
    end

    entries
end
