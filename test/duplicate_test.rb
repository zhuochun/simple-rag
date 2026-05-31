require_relative "../server/duplicate"
require "digest"

def assert_equal(expected, actual)
  raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

def duplicate_item(path, chunk)
  {
    path: "lookup",
    id: path,
    url: path,
    source_path: path,
    chunk: chunk,
    hash: Digest::SHA256.hexdigest("#{path}##{chunk}"),
    embedding: [1.0, 0.0],
    bucket: 0,
    text: "#{path}##{chunk}",
  }
end

items = [
  duplicate_item("same.md", 0),
  duplicate_item("same.md", 1),
]
assert_equal 2, pre_dedup_duplicate_items(items).length

FakeStore = Struct.new(:rows, :calls) do
  def vector_search(_embedding, _limit)
    self.calls = calls.to_i + 1
    rows
  end
end

items = [
  duplicate_item("left.md", 0),
  duplicate_item("right.md", 0),
]
buckets = Hash.new { |hash, key| hash[key] = [] }
store = FakeStore.new([{ "path" => "right.md", "chunk" => 0 }], 0)
by_source_path, by_source_path_chunk = build_index_maps(items)
candidates = candidate_indices_for_item(items, buckets, 0, store, by_source_path, by_source_path_chunk)
assert_equal [1], candidates
assert_equal 1, store.calls

adjacency, = build_similarity_graph(items, buckets, 0.99, false)
assert_equal [1], adjacency[0].to_a
assert_equal [0], adjacency[1].to_a

puts "duplicate_test: passed"
