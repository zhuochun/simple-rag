require_relative "../server/retriever"
require "ostruct"
require "tmpdir"
require_relative "test_assertions"

class RetrieverTest
  include TestAssertions

  class FakeCatalog
    attr_reader :embedding, :k

    def vector_search(_paths, embedding, k:)
      @embedding = embedding
      @k = k
      [
        hit("low.md", 0.5),
        hit("high.md", 0.9),
        hit("middle.md", 0.7),
      ]
    end

    private

    def hit(path, score)
      { "path" => path, "chunk" => 0, "score" => score, "lookup" => "notes", "text" => path }
    end
  end

  class FakeStore
    attr_reader :closed

    def vector_search(_embedding, _limit)
      [{ "path" => "folder/note.md", "chunk" => 2, "score" => 0.8, "text" => "note" }]
    end

    def close
      @closed = true
    end
  end

  def test_similarity_retriever_normalizes_orders_and_limits_results
    catalog = FakeCatalog.new
    retriever = SimpleRag::SimilarityRetriever.new(
      embedding_fn: ->(_query) { [3.0, 4.0] },
      catalog: catalog
    )

    results = retriever.retrieve([:notes], "query", top_n: 2)

    assert_equal %w[high.md middle.md], results.map { |row| row["path"] }
    assert_equal [0.6, 0.8], catalog.embedding
    assert_equal 64, catalog.k
  end

  def test_similarity_retriever_owns_its_input_validation
    embedding_calls = 0
    retriever = SimpleRag::SimilarityRetriever.new(
      embedding_fn: ->(_query) { embedding_calls += 1; [1.0, 0.0] },
      catalog: FakeCatalog.new
    )

    assert_raises(RetrievalInputError) { retriever.retrieve([], "query", top_n: 2) }
    assert_raises(RetrievalInputError) { retriever.retrieve([:notes], " ", top_n: 2) }
    assert_raises(RetrievalInputError) { retriever.retrieve([:notes], "query", top_n: 0) }
    assert_raises(RetrievalInputError) { retriever.retrieve([:notes], "query", top_n: 101) }
    assert_equal 0, embedding_calls
  end

  def test_index_catalog_decorates_hits_and_reuses_stores_until_close
    store = FakeStore.new
    path = OpenStruct.new(name: "notes", threshold: 0.5, url: "https://notes/")
    opens = 0
    catalog = SimpleRag::IndexCatalog.new(store_factory: ->(_path) { opens += 1; store })

    rows = catalog.vector_search([path], [1.0, 0.0], k: 10)

    assert_equal "notes", rows.first["lookup"]
    assert_equal "folder/note.md", rows.first["id"].tr("\\", "/")
    assert_equal "https://notes/note", rows.first["url"]
    assert_equal nil, store.closed
    assert_equal rows, catalog.vector_search([path], [1.0, 0.0], k: 10)
    assert_equal 1, opens
    catalog.close
    assert_equal true, store.closed
  end

  def test_pooled_catalog_sees_an_index_populated_after_an_empty_query
    Dir.mktmpdir('pooled-index-') do |dir|
      path = OpenStruct.new(name: 'notes', threshold: 0.0, db_file: File.join(dir, 'index.sqlite'), db_table: 'chunks')
      catalog = SimpleRag::IndexCatalog.new
      assert_equal [], catalog.vector_search([path], [1.0, 0.0], k: 10)
      writer = SqliteIndex.new(path.db_file, path.db_table)
      writer.transaction do
        writer.upsert_chunks([{ path: 'note.md', chunk: 0, hash: 'alpha', embedding: [1.0, 0.0], text: 'alpha' }])
      end
      assert_equal ['alpha'], catalog.vector_search([path], [1.0, 0.0], k: 10).map { |row| row['text'] }
    ensure
      writer&.close
      catalog&.close
    end
  end

  private

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

end

if $PROGRAM_NAME == __FILE__
  test = RetrieverTest.new
  test.test_similarity_retriever_normalizes_orders_and_limits_results
  puts "test_similarity_retriever_normalizes_orders_and_limits_results: passed"
  test.test_similarity_retriever_owns_its_input_validation
  puts "test_similarity_retriever_owns_its_input_validation: passed"
  test.test_index_catalog_decorates_hits_and_reuses_stores_until_close
  puts "test_index_catalog_decorates_hits_and_reuses_stores_until_close: passed"
  test.test_pooled_catalog_sees_an_index_populated_after_an_empty_query
  puts "test_pooled_catalog_sees_an_index_populated_after_an_empty_query: passed"
end
