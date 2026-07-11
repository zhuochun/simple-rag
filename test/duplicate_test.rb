require "ostruct"

require_relative "../server/duplicate"

class DuplicateFinderTest
  class FakeCatalog
    def initialize(entries)
      @entries = entries
    end

    def each_item(_paths)
      @entries.each { |path, row| yield path, row }
    end
  end

  def test_find_returns_complete_link_clusters_with_stable_ids
    path = OpenStruct.new(name: "notes", url: nil)
    catalog = FakeCatalog.new([
      [path, row("left.md", [1.0, 0.0])],
      [path, row("right.md", [0.999, 0.001])],
      [path, row("other.md", [0.0, 1.0])],
    ])
    finder = SimpleRag::DuplicateFinder.new(catalog: catalog)

    clusters = finder.find([path], threshold: 0.99, cross_document_only: true)

    assert_equal 1, clusters.length
    assert_equal "left.md#0|right.md#0", clusters.first[:id]
    assert_equal %w[left.md right.md], clusters.first[:items].map { |item| item[:source_path] }.sort
  end

  private

  def row(path, embedding)
    {
      "path" => path,
      "chunk" => 0,
      "hash" => "#{path}-0",
      "embedding" => embedding,
      "bucket" => EmbeddingMath.bucket_key(EmbeddingMath.normalize(embedding)),
      "text" => path
    }
  end

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end
end

if $PROGRAM_NAME == __FILE__
  test = DuplicateFinderTest.new
  test.test_find_returns_complete_link_clusters_with_stable_ids
  puts "test_find_returns_complete_link_clusters_with_stable_ids: passed"
end
