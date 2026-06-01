require "pathname"
require "json"
require "etc"
require "thread"

require_relative "cache"
require_relative "../llm/llm"
require_relative "../llm/embedding"
require_relative "../storage/sqlite_index"
require_relative "retrieval_pipeline"

VECTOR_SEARCH_K = 512
VECTOR_SEARCH_K_MIN = 64
VECTOR_SEARCH_K_MULTIPLIER = 12
RETRIEVE_THREADS_MAX = 8
RETRIEVE_PROGRESS_LOG = ENV["RAG_RETRIEVE_PROGRESS"].to_s == "1"

def retrieve_progress(message)
    return unless RETRIEVE_PROGRESS_LOG

    STDOUT << message
end

def with_sqlite_store(path_config)
    store = SqliteIndex.new(path_config.db_file, path_config.db_table)
    begin
        yield(store)
    ensure
        store.close
    end
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
    errors = Queue.new
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
                errors << [path, e]
            end
        end
    end
    threads.each(&:join)
    unless errors.empty?
        path, error = errors.pop
        raise RuntimeError, "Path retrieval failed (#{path&.name || "unknown"}): #{error.class}: #{error.message}"
    end
end

def vector_search_k_for_top_n(top_n)
    n = top_n.to_i
    return VECTOR_SEARCH_K if n <= 0

    [[n * VECTOR_SEARCH_K_MULTIPLIER, VECTOR_SEARCH_K_MIN].max, VECTOR_SEARCH_K].min
end

def retrieve_by_embedding(lookup_paths, q, top_n: nil, parallel: true, use_cache: true)
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

        path_entries = []
        with_sqlite_store(p) do |store|
            store.vector_search(qn, k).each do |item|
                score = item["score"].to_f
                next if score < p.threshold

                path_entries << {
                    "path" => item["path"],
                    "chunk" => item["chunk"],
                    "score" => score,
                    "lookup" => p.name,
                    "id" => extract_id(item["path"]),
                    "url" => extract_url(item["path"], p.url),
                    "text" => item["text"]
                }
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

def cached_embedding(query)
    CACHE.get_or_set(query, method(:embedding).to_proc)
end

def build_retriever
    Retriever.new(
        planner: QueryPlanner.new(chat_fn: method(:chat)),
        executor: RetrievalExecutor.new(
            embedding_fn: method(:cached_embedding),
            id_fn: method(:extract_id),
            url_fn: method(:extract_url)
        )
    )
end
