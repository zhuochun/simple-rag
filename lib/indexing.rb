require "stringio"
require "thread"
require "digest"
require "set"

require_relative "../storage/sqlite_index"
require_relative "../llm/embedding"

module SimpleRag
  module Indexing
    class Indexer
      def initialize(embedding_fn:, reader_resolver:, store_factory: nil, clock: nil)
        @embedding_fn = embedding_fn
        @reader_resolver = reader_resolver
        @store_factory = store_factory || ->(path) { SqliteIndex.new(path.db_file, path.db_table) }
        @clock = clock || -> { Time.now }
      end

      def index(path, out:, status:, allow_empty_prune:, build_mode:)
        validate_path!(path)
        out << "Read path name: #{path.name}, reader: #{path.reader}\n"
        status.call("Reading index")

        index_file_existed = index_file_existed?(path.db_file)
        scan_started_at = @clock.call
        out << "Read existing sqlite index: #{path.db_file}@#{path.db_table}, time: @#{@clock.call}\n"
        store = @store_factory.call(path)
        out << "Found index rows: #{store.row_count}\n"

        last_scan_at = store.last_scan_completed_at
        actual_build_mode, fallback_reason = resolve_build_mode(build_mode, index_file_existed, last_scan_at)
        out << "Build mode: #{actual_build_mode}"
        out << " (requested #{build_mode}; #{fallback_reason})" if fallback_reason
        out << "\n"
        out << "Last scan timestamp: #{last_scan_at ? format_scan_timestamp(last_scan_at) : 'none'}\n"

        reader_class = resolve_reader(path)
        matched_files, files_to_index = select_files(
          path,
          out,
          status,
          build_mode: actual_build_mode,
          last_scan_at: last_scan_at
        )
        out << "Matched files: #{matched_files.length}\n"
        if actual_build_mode == "delta"
          out << "Files to read modified since #{format_scan_timestamp(last_scan_at)}: #{files_to_index.length}\n"
        else
          out << "Files to read for full build: #{files_to_index.length}\n"
        end

        process_files(
          path,
          store,
          reader_class,
          matched_files,
          files_to_index,
          scan_started_at,
          out,
          status,
          allow_empty_prune
        )
      ensure
        store&.close
      end

      private

      def process_files(path, store, reader_class, matched_files, files_to_index, scan_started_at, out, status, allow_empty_prune)
        errors = 0
        read_files = 0
        skipped = 0
        created = 0
        prune_skipped = false

        out << "Building index @#{@clock.call}\n["
        status.call(progress_line(path.name, matched_files.length, read_files, created, skipped, errors))

        files_to_index.each do |file|
          read_files += 1
          status.call(progress_line(path.name, matched_files.length, read_files, created, skipped, errors))
          chunks = read_chunks(reader_class, file, out)
          if chunks.nil?
            errors += 1
            next
          end

          result = build_file_rows(store, file, chunks, out)
          errors += result[:errors]
          created += result[:created]
          skipped += result[:skipped]

          store.transaction do
            store.upsert_chunks(result[:rows])
            store.delete_stale_chunks(file, result[:valid_chunks])
          end
          out << ((read_files - 1) % 50 == 0 ? (read_files - 1).to_s : ".")
        end

        if matched_files.empty? && !allow_empty_prune
          out << "Empty scan guard: skipping stale prune for #{path.name}. Re-run with --allow-empty-prune to allow pruning on empty scan.\n"
          prune_skipped = true
        elsif matched_files.empty?
          out << "\nallow-empty-prune enabled: pruning all rows in table #{path.db_table} due to empty scan.\n"
        end

        store.transaction { store.delete_stale_paths(matched_files) } unless prune_skipped

        if errors.zero? && !prune_skipped
          store.record_scan_completed_at(scan_started_at)
          out << "Recorded scan timestamp: #{format_scan_timestamp(scan_started_at.to_f)}\n"
        else
          reasons = []
          reasons << "#{errors} errors occurred" unless errors.zero?
          reasons << "stale prune was skipped" if prune_skipped
          out << "Scan timestamp not updated because #{reasons.join(' and ')}.\n"
        end

        out << "]\nDone @#{@clock.call}, Matched: #{matched_files.length}, Read: #{read_files}, Created: #{created}, Skipped: #{skipped}, Errors: #{errors}\n"
        status.call(progress_line(path.name, matched_files.length, read_files, created, skipped, errors))
        {
          created: created,
          skipped: skipped,
          errors: errors,
          matched_files: matched_files.length,
          read_files: read_files,
          prune_skipped: prune_skipped
        }
      end

      def read_chunks(reader_class, file, out)
        reader_class.new(file).load.chunks
      rescue => error
        out << "\nError reading #{file}: #{error.class}: #{error.message}\n"
        out << "Backtrace: #{error.backtrace&.first}\n"
        nil
      end

      def build_file_rows(store, file, chunks, out)
        valid_chunks = Set.new
        rows = []
        changed_hashes = Set.new
        chunk_rows = []
        existing_hashes = store.chunk_hash_lookup_for_path(file)
        errors = 0

        chunks.each_with_index do |chunk, chunk_index|
          hash = Digest::SHA256.hexdigest(chunk)
          chunk_rows << [chunk_index, chunk, hash]
          valid_chunks.add(chunk_index)
          changed_hashes.add(hash) unless existing_hashes[chunk_index] == hash
        rescue => error
          errors += 1
          record_chunk_error(out, file, chunk_index, error, hash)
        end

        embeddings, lookup_errors = existing_embeddings(store, changed_hashes, file, out)
        errors += lookup_errors
        created = 0
        skipped = 0
        chunk_rows.each do |chunk_index, chunk, hash|
          if existing_hashes[chunk_index] == hash
            skipped += 1
            next
          end

          embedding = embeddings[hash]
          if embedding.nil?
            embedding = @embedding_fn.call(chunk)
            created += 1
            embeddings[hash] = embedding
          end
          raise "Embedding missing for hash=#{hash}" if embedding.nil?

          normalized = EmbeddingMath.normalize(embedding)
          rows << {
            path: file,
            chunk: chunk_index,
            hash: hash,
            embedding: embedding,
            bucket: EmbeddingMath.bucket_key(normalized),
            text: chunk
          }
        rescue => error
          errors += 1
          record_chunk_error(out, file, chunk_index, error, hash)
        end

        { rows: rows, valid_chunks: valid_chunks, created: created, skipped: skipped, errors: errors }
      end

      def existing_embeddings(store, hashes, file, out)
        [store.embeddings_for_hashes(hashes.to_a), 0]
      rescue => error
        out << "\nError loading existing embeddings for file=#{file}: #{error.class}: #{error.message}\n"
        out << "Backtrace: #{error.backtrace&.first}\n"
        [{}, 1]
      end

      def record_chunk_error(out, file, chunk_index, error, hash)
        out << "\nError indexing file=#{file}, chunk=#{chunk_index}: #{error.class}: #{error.message}\n"
        out << "Hash: #{hash}\n" if hash
        out << "Backtrace: #{error.backtrace&.first}\n"
      end

      def select_files(path, out, status, build_mode:, last_scan_at:)
        matched = []
        selected = []
        each_scanned_file(path, out, status) do |file|
          matched << file
          selected << file unless build_mode == "delta" && last_scan_at && !modified_after?(file, last_scan_at)
        end
        [matched, selected]
      end

      def each_scanned_file(path, out, status)
        status.call("Scanning dir")
        name_match = path.nameMatch || "*.{md,markdown}"
        glob = File.join(File.expand_path(path.dir), "**", name_match)
        out << "Scan dir: #{glob}\n"
        Dir.glob(glob).each { |file| yield file if File.file?(file) }
      end

      def resolve_reader(path)
        reader = @reader_resolver.call(path.reader)
        raise ArgumentError, "Reader undefined: #{path.reader}" unless reader

        reader
      end

      def validate_path!(path)
        return if path.db_file && path.db_table

        raise ArgumentError, %(Path "#{path.name}" must set "db".)
      end

      def index_file_existed?(db_file)
        return false if db_file.to_s == ":memory:"

        File.exist?(File.expand_path(db_file))
      end

      def resolve_build_mode(requested, index_existed, last_scan_at)
        return ["full", nil] if requested == "full"
        return ["full", "index does not exist"] unless index_existed
        return ["full", "scan timestamp is missing"] if last_scan_at.nil?

        ["delta", nil]
      end

      def modified_after?(file, timestamp)
        File.mtime(file).to_f > timestamp.to_f
      rescue
        true
      end

      def format_scan_timestamp(timestamp)
        Time.at(timestamp.to_f).strftime("%Y-%m-%d %H:%M:%S %z")
      end

      def progress_line(path_name, matched, read, created, skipped, errors)
        "#{path_name}: Match #{matched}, Read #{read} files | Create #{created}, Skip #{skipped}, Err #{errors} chunks"
      end
    end

    class RunResult
      attr_reader :path, :summary, :output

      def initialize(path:, summary:, output:, error: nil)
        @path = path
        @summary = summary
        @output = output
        @error = error
      end

      def failed?
        !@error.nil? || summary.nil? || summary[:errors].to_i.positive?
      end
    end

    class Runner
      DEFAULT_WORKERS = 4

      def initialize(indexer:, workers: DEFAULT_WORKERS)
        @indexer = indexer
        @workers = [workers.to_i, 1].max
      end

      def run(paths, allow_empty_prune:, build_mode:, on_status: nil)
        entries = Array(paths)
        return [] if entries.empty?

        queue = Queue.new
        entries.each_with_index { |path, index| queue << [index, path] }
        results = Array.new(entries.length)
        worker_count = [entries.length, @workers].min

        workers = worker_count.times.map do
          Thread.new do
            loop do
              index, path = queue.pop(true)
              results[index] = run_path(
                path,
                allow_empty_prune: allow_empty_prune,
                build_mode: build_mode,
                on_status: on_status
              )
            rescue ThreadError
              break
            end
          end
        end
        workers.each(&:join)
        results
      end

      private

      def run_path(path, allow_empty_prune:, build_mode:, on_status:)
        name = path.respond_to?(:name) ? path.name.to_s : path.to_s
        output = StringIO.new
        summary = @indexer.index(
          path,
          out: output,
          status: ->(message) { on_status&.call(name, message) },
          allow_empty_prune: allow_empty_prune,
          build_mode: build_mode
        )
        RunResult.new(path: name, summary: summary, output: output.string)
      rescue => error
        output << "\nIndex error: #{error.class}: #{error.message}\n"
        output << "Backtrace: #{error.backtrace&.first}\n"
        RunResult.new(path: name, summary: summary, output: output.string, error: error)
      end
    end
  end
end
