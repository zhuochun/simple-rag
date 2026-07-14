require_relative "../server/retriever"
require "ostruct"

class RetrieverTest
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

  def test_index_catalog_decorates_hits_and_closes_stores
    store = FakeStore.new
    path = OpenStruct.new(name: "notes", threshold: 0.5, url: "https://notes/")
    catalog = SimpleRag::IndexCatalog.new(store_factory: ->(_path) { store })

    rows = catalog.vector_search([path], [1.0, 0.0], k: 10)

    assert_equal "notes", rows.first["lookup"]
    assert_equal "folder/note.md", rows.first["id"].tr("\\", "/")
    assert_equal "https://notes/note", rows.first["url"]
    assert_equal true, store.closed
  end

  private

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

  def assert_raises(error_class)
    yield
    raise "Expected #{error_class}, but nothing was raised"
  rescue error_class => error
    error
  end
end

if $PROGRAM_NAME == __FILE__
  test = RetrieverTest.new
  test.test_similarity_retriever_normalizes_orders_and_limits_results
  puts "test_similarity_retriever_normalizes_orders_and_limits_results: passed"
  test.test_similarity_retriever_owns_its_input_validation
  puts "test_similarity_retriever_owns_its_input_validation: passed"
  test.test_index_catalog_decorates_hits_and_closes_stores
  puts "test_index_catalog_decorates_hits_and_closes_stores: passed"
end
