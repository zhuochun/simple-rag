require "digest"
require "fileutils"
require "tmpdir"

require_relative "../storage/sqlite_index"
require_relative "../lib/query_helpers"

class SqliteIndexTest
  def setup
    @tmpdir = Dir.mktmpdir("sqlite-index-", __dir__)
    @store = SqliteIndex.new(File.join(@tmpdir, "index.sqlite"), "chunks")
  end

  def teardown
    @store&.close
    expanded_tmpdir = File.expand_path(@tmpdir)
    test_dir = "#{File.expand_path(__dir__)}#{File::SEPARATOR}"
    FileUtils.remove_entry(expanded_tmpdir) if expanded_tmpdir.start_with?(test_dir)
  end

  def test_vector_search_uses_cosine_distance
    upsert("cosine.md", 0, "cosine", [10.0, 0.0])
    upsert("l2.md", 0, "l2", [1.0, 0.1])

    results = @store.vector_search([1.0, -0.1], 1)

    assert_equal ["cosine.md"], results.map { |row| row["path"] }
    assert_operator results.first["score"], :>, 0.99
  end

  def test_text_search_uses_bm25_and_tracks_updates_and_deletes
    upsert("frequent.md", 0, "legacyterm rare rare rare", [1.0, 0.0])
    upsert("single.md", 0, "rare", [0.0, 1.0])

    results = @store.text_search_any(["rare"])
    assert_equal ["frequent.md", "single.md"], results.map { |row| row["path"] }
    assert_operator results[0]["score"], :>, results[1]["score"]

    upsert("frequent.md", 0, "freshterm", [1.0, 0.0])
    assert_empty @store.text_search_any(["legacyterm"])
    assert_equal ["frequent.md"], @store.text_search_any(["freshterm"]).map { |row| row["path"] }

    @store.delete_stale_chunks("frequent.md", [])
    assert_empty @store.text_search_any(["freshterm"])
  end

  def test_text_search_supports_tokenized_and_phrase_queries
    upsert("separated.md", 0, "database resilient timeout", [1.0, 0.0])
    upsert("phrase.md", 0, "database timeout", [0.0, 1.0])

    tokenized = @store.text_search_any(["database timeout"])
    phrase = @store.text_search_any(["database timeout"], phrase: true)

    assert_equal ["separated.md", "phrase.md"].sort, tokenized.map { |row| row["path"] }.sort
    assert_equal ["phrase.md"], phrase.map { |row| row["path"] }
  end

  def test_find_chunk_and_random_chunks_return_indexed_text
    upsert("indexed.md", 2, "stored text", [1.0, 0.0])

    row = @store.find_chunk("indexed.md", 2, hash: Digest::SHA256.hexdigest("stored text"))
    assert_equal "stored text", row["text"]
    assert_equal ["stored text"], @store.random_chunks(1).map { |item| item["text"] }
  end

  def test_in_memory_store_supports_vector_search
    store = SqliteIndex.new(":memory:", "chunks")
    store.upsert_chunk(
      path: "memory.md",
      chunk: 0,
      hash: Digest::SHA256.hexdigest("memory"),
      embedding: [1.0, 0.0],
      bucket: 0,
      text: nil
    )

    assert_equal ["memory.md"], store.vector_search([1.0, 0.0], 1).map { |row| row["path"] }
  ensure
    store&.close
  end

  def test_scan_timestamp_is_stored_per_index_table
    assert_equal nil, @store.last_scan_completed_at

    @store.record_scan_completed_at(Time.at(1234.5))
    assert_operator @store.last_scan_completed_at, :>, 1234.0

    other = SqliteIndex.new(File.join(@tmpdir, "index.sqlite"), "other_chunks")
    assert_equal nil, other.last_scan_completed_at
  ensure
    other&.close
  end

  def test_serialize_entries_uses_indexed_text_without_loading_reader
    reader = Object.new
    def reader.load
      raise "reader should not be loaded"
    end

    rows = QueryHelpers.serialize_entries([
      {
        "path" => "indexed.md",
        "chunk" => 0,
        "text" => "stored text",
        "reader" => reader
      }
    ])

    assert_equal "stored text", rows.first[:text]
  end

  private

  def assert_empty(value)
    raise "Expected empty value, got #{value.inspect}" unless value.empty?
  end

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

  def assert_operator(left, operator, right)
    return if left.public_send(operator, right)

    raise "Expected #{left.inspect} #{operator} #{right.inspect}"
  end

  def upsert(path, chunk, text, embedding)
    @store.upsert_chunk(
      path: path,
      chunk: chunk,
      hash: Digest::SHA256.hexdigest(text),
      embedding: embedding,
      bucket: 0,
      text: text
    )
  end
end

if $PROGRAM_NAME == __FILE__
  tests = %w[
    test_vector_search_uses_cosine_distance
    test_text_search_uses_bm25_and_tracks_updates_and_deletes
    test_text_search_supports_tokenized_and_phrase_queries
    test_find_chunk_and_random_chunks_return_indexed_text
    test_in_memory_store_supports_vector_search
    test_scan_timestamp_is_stored_per_index_table
    test_serialize_entries_uses_indexed_text_without_loading_reader
  ]

  tests.each do |name|
    test = SqliteIndexTest.new
    begin
      test.setup
      test.public_send(name)
      puts "#{name}: passed"
    ensure
      test.teardown
    end
  end
end
