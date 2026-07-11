require "pathname"
require "thread"

require_relative "../storage/sqlite_index"

module SimpleRag
  class DocumentLocator
    def id(file_path)
      parts = Pathname.new(file_path.to_s).each_filename.to_a
      File.join(parts.last(2))
    end

    def url(file_path, prefix)
      return "file://#{file_path}" if prefix.to_s.empty?

      path = Pathname.new(file_path.to_s)
      "#{prefix}#{path.basename(path.extname)}"
    end
  end

  class IndexCatalog
    THREADS_MAX = 8

    def initialize(locator: DocumentLocator.new, store_factory: nil, threads_max: THREADS_MAX)
      @locator = locator
      @store_factory = store_factory || ->(path) { SqliteIndex.new(path.db_file, path.db_table) }
      @threads_max = [[threads_max.to_i, 1].max, THREADS_MAX].min
    end

    def warm!(paths)
      parallel_map(paths) { |path| with_store(path) { |store| store.warm_vector_index! } }
      true
    end

    def find_chunk(path_config, path, chunk, hash: nil)
      with_store(path_config) { |store| store.find_chunk(path, chunk, hash: hash) }
    end

    def random(paths, count)
      sample_size = count.to_i
      return [] unless sample_size.positive?

      parallel_map(paths) do |path|
        with_store(path) do |store|
          store.random_chunks(sample_size).map { |row| decorate(row, path, score: 0.0) }
        end
      end.flatten.sample(sample_size)
    end

    def vector_search(paths, embedding, k:)
      parallel_map(paths) do |path|
        with_store(path) do |store|
          store.vector_search(embedding, k).filter_map do |row|
            score = row["score"].to_f
            next if score < path.threshold.to_f

            decorate(row, path, score: score)
          end
        end
      end.flatten
    end

    def each_item(paths)
      return enum_for(__method__, paths) unless block_given?

      Array(paths).each do |path|
        with_store(path) { |store| store.each_item { |row| yield path, row } }
      end
    end

    private

    def decorate(row, path, score:)
      {
        "path" => row["path"],
        "chunk" => row["chunk"].to_i,
        "score" => score,
        "lookup" => path.name,
        "id" => @locator.id(row["path"]),
        "url" => @locator.url(row["path"], path.url),
        "text" => row["text"]
      }
    end

    def with_store(path)
      store = @store_factory.call(path)
      yield store
    ensure
      store&.close
    end

    def parallel_map(paths)
      entries = Array(paths).compact
      return [] if entries.empty?
      return entries.map { |path| yield path } if entries.length == 1

      queue = Queue.new
      entries.each_with_index { |path, index| queue << [index, path] }
      results = Array.new(entries.length)
      errors = Queue.new
      workers = [entries.length, @threads_max].min.times.map do
        Thread.new do
          loop do
            item = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            index, path = item
            begin
              results[index] = yield path
            rescue => error
              errors << [path, error]
              break
            end
          end
        end
      end
      workers.each(&:join)
      unless errors.empty?
        path, error = errors.pop
        raise RuntimeError, "Index access failed for #{path&.name || 'unknown'}: #{error.class}: #{error.message}"
      end
      results
    end
  end
end
