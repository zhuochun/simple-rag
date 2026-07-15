require "ostruct"

require_relative "../server/dismissal_store"
require_relative "../server/retriever"
require_relative "../server/runtime"
require_relative "test_assertions"

class ServerRuntimeTest
  include TestAssertions

  class FakeRetriever
    attr_reader :request

    def retrieve_q(paths, query, top_n:)
      @request = [paths.map(&:name), query, top_n]
      { data: [] }
    end

    def close; end
  end

  class FakeDuplicateFinder
    def find(_paths, threshold:, cross_document_only:)
      raise "unexpected threshold" unless threshold == 0.9
      raise "expected cross-document mode" unless cross_document_only
      [{ id: "cluster-1", items: [] }]
    end
  end

  class FakeSimilarityCatalog
    def vector_search(_paths, embedding, k:)
      raise "expected normalized embedding" unless embedding == [1.0, 0.0]
      raise "expected bounded search depth" unless k == 64

      [{
        "path" => "alpha.md",
        "lookup" => "notes",
        "id" => "alpha.md",
        "url" => "file://alpha.md",
        "chunk" => 0,
        "score" => 0.9,
        "text" => "alpha text"
      }]
    end
  end

  def test_query_resolves_default_paths_and_delegates
    retriever = FakeRetriever.new
    runtime = build_runtime(retriever: retriever)

    result = runtime.query({ "q" => "systems", "topN" => 5 })

    assert_equal({ data: [] }, result)
    assert_equal [["notes"], "systems", 5], retriever.request
  end

  def test_dismissed_duplicate_clusters_are_filtered
    runtime = build_runtime
    assert_equal 1, runtime.duplicates({})[:clusters].length

    runtime.dismiss("id" => "cluster-1")

    assert_equal [], runtime.duplicates({})[:clusters]
  end

  def test_similar_preserves_validation_and_serialized_response
    embedding_calls = 0
    similarity_retriever = SimpleRag::SimilarityRetriever.new(
      embedding_fn: ->(_query) { embedding_calls += 1; [2.0, 0.0] },
      catalog: FakeSimilarityCatalog.new
    )
    runtime = build_runtime(similarity_retriever: similarity_retriever)

    error = assert_raises(RetrievalInputError) { runtime.similar("note" => " ") }
    assert_equal "Query text is required", error.message
    assert_equal 0, embedding_calls

    result = runtime.similar("note" => "alpha", "topN" => 1)
    assert_equal 1, embedding_calls
    assert_equal "alpha.md", result[:data].first[:path]
    assert_equal "alpha text", result[:data].first[:text]
  end

  private

  def build_runtime(retriever: FakeRetriever.new, similarity_retriever: Object.new)
    path = OpenStruct.new(name: "notes", searchDefault: true)
    config = OpenStruct.new(paths: [path], path_map: { "notes" => path })
    SimpleRag::ServerRuntime.new(
      config_file: "config.json",
      config_digest: "digest",
      config: config,
      retriever: retriever,
      similarity_retriever: similarity_retriever,
      duplicate_finder: FakeDuplicateFinder.new,
      catalog: Object.new,
      locator: Object.new,
      dismissals: SimpleRag::DismissalStore.new(nil),
      article_reader: Object.new,
      discuss_fn: ->(_note, _query) { "discussion" }
    )
  end

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

end

if $PROGRAM_NAME == __FILE__
  test = ServerRuntimeTest.new
  test.test_query_resolves_default_paths_and_delegates
  puts "test_query_resolves_default_paths_and_delegates: passed"
  test.test_dismissed_duplicate_clusters_are_filtered
  puts "test_dismissed_duplicate_clusters_are_filtered: passed"
  test.test_similar_preserves_validation_and_serialized_response
  puts "test_similar_preserves_validation_and_serialized_response: passed"
end
