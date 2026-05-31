require_relative "../server/duplicate"

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
    embedding: [1.0, 0.0],
    bucket: 0,
    text: "#{path}##{chunk}",
    db_key: path,
  }
end

items = [
  duplicate_item("same.md", 0),
  duplicate_item("same.md", 1),
]
assert_equal 2, pre_dedup_duplicate_items(items).length

FakeStore = Struct.new(:rows) do
  def vector_search(_embedding, _limit)
    rows
  end
end

def with_sqlite_store(store, _cache = nil)
  yield(store)
end

items = [
  duplicate_item("left.md", 0),
  duplicate_item("right.md", 0),
]
buckets = Hash.new { |hash, key| hash[key] = [] }
configs = {
  "left" => FakeStore.new([]),
  "right" => FakeStore.new([{ "path" => "right.md", "chunk" => 0 }]),
}
by_source_path, by_source_path_chunk = build_index_maps(items)
candidates = candidate_indices_for_item(items, buckets, 0, configs, {}, by_source_path, by_source_path_chunk)
assert_equal [1], candidates

puts "duplicate_test: passed"
