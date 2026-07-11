require "ostruct"

require_relative "../server/dismissal_store"
require_relative "../server/runtime"

class ServerRuntimeTest
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

  private

  def build_runtime(retriever: FakeRetriever.new)
    path = OpenStruct.new(name: "notes", searchDefault: true)
    config = OpenStruct.new(paths: [path], path_map: { "notes" => path })
    SimpleRag::ServerRuntime.new(
      config_file: "config.json",
      config_digest: "digest",
      config: config,
      retriever: retriever,
      similarity_retriever: Object.new,
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
end
