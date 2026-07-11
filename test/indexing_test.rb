require "stringio"
require "thread"
require "fileutils"
require "ostruct"
require "tmpdir"

require_relative "../lib/indexing"

class IndexingTest
  ReaderResult = Struct.new(:chunks)

  class FakeReader
    def initialize(file)
      @file = file
    end

    def load
      ReaderResult.new(File.read(@file).split("\n"))
    end
  end

  class FailingEmbeddingLookupStore < SqliteIndex
    def embeddings_for_hashes(_hashes)
      raise "lookup failed"
    end
  end

  FakeIndexer = Struct.new(:mutex, :active, :max_active) do
    def index(path, out:, status:, allow_empty_prune:, build_mode:)
      mutex.synchronize do
        self.active += 1
        self.max_active = [max_active, active].max
      end
      sleep 0.02
      out << "indexed #{path}\n"
      status.call("done")
      { matched_files: 1, read_files: 1, created: 1, skipped: 0, errors: 0 }
    ensure
      mutex.synchronize { self.active -= 1 }
    end
  end

  def test_runner_limits_concurrency_and_preserves_path_order
    indexer = FakeIndexer.new(Mutex.new, 0, 0)
    runner = SimpleRag::Indexing::Runner.new(indexer: indexer, workers: 2)
    statuses = []
    status_mutex = Mutex.new

    results = runner.run(
      %w[alpha beta gamma delta],
      allow_empty_prune: false,
      build_mode: "delta",
      on_status: ->(path, message) { status_mutex.synchronize { statuses << [path, message] } }
    )

    assert_equal %w[alpha beta gamma delta], results.map(&:path)
    assert_equal 2, indexer.max_active
    assert_equal [false, false, false, false], results.map(&:failed?)
    assert_equal true, statuses.include?(["alpha", "done"])
  end

  def test_indexer_builds_then_skips_unchanged_files_in_delta_mode
    Dir.mktmpdir("indexing-test-", __dir__) do |dir|
      note = File.join(dir, "note.md")
      File.write(note, "alpha\nbeta")
      File.utime(Time.at(900), Time.at(900), note)
      path = OpenStruct.new(
        name: "notes",
        reader: "fake",
        dir: dir,
        nameMatch: "*.md",
        db_file: File.join(dir, "index.sqlite"),
        db_table: "chunks"
      )
      indexer = SimpleRag::Indexing::Indexer.new(
        embedding_fn: ->(text) { text == "alpha" ? [1.0, 0.0] : [0.0, 1.0] },
        reader_resolver: ->(_name) { FakeReader },
        clock: -> { Time.at(1000) }
      )

      first = indexer.index(
        path,
        out: StringIO.new,
        status: ->(_message) {},
        allow_empty_prune: false,
        build_mode: "delta"
      )
      second = indexer.index(
        path,
        out: StringIO.new,
        status: ->(_message) {},
        allow_empty_prune: false,
        build_mode: "delta"
      )

      assert_equal 2, first[:created]
      assert_equal 1, first[:read_files]
      assert_equal 0, second[:read_files]
      store = SqliteIndex.new(path.db_file, path.db_table)
      assert_equal 2, store.row_count
      store.close
    end
  end

  def test_indexer_does_not_advance_scan_timestamp_after_storage_lookup_error
    Dir.mktmpdir("indexing-error-", __dir__) do |dir|
      note = File.join(dir, "note.md")
      File.write(note, "alpha")
      path = OpenStruct.new(
        name: "notes",
        reader: "fake",
        dir: dir,
        nameMatch: "*.md",
        db_file: File.join(dir, "index.sqlite"),
        db_table: "chunks"
      )
      indexer = SimpleRag::Indexing::Indexer.new(
        embedding_fn: ->(_text) { [1.0, 0.0] },
        reader_resolver: ->(_name) { FakeReader },
        store_factory: ->(configured_path) { FailingEmbeddingLookupStore.new(configured_path.db_file, configured_path.db_table) }
      )

      result = indexer.index(
        path,
        out: StringIO.new,
        status: ->(_message) {},
        allow_empty_prune: false,
        build_mode: "full"
      )

      assert_equal 1, result[:errors]
      store = SqliteIndex.new(path.db_file, path.db_table)
      assert_equal nil, store.last_scan_completed_at
      store.close
    end
  end

  private

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end
end

if $PROGRAM_NAME == __FILE__
  test = IndexingTest.new
  test.test_runner_limits_concurrency_and_preserves_path_order
  puts "test_runner_limits_concurrency_and_preserves_path_order: passed"
  test.test_indexer_builds_then_skips_unchanged_files_in_delta_mode
  puts "test_indexer_builds_then_skips_unchanged_files_in_delta_mode: passed"
  test.test_indexer_does_not_advance_scan_timestamp_after_storage_lookup_error
  puts "test_indexer_does_not_advance_scan_timestamp_after_storage_lookup_error: passed"
end
