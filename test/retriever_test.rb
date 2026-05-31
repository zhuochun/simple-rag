require "ostruct"

require_relative "../server/retriever"
require_relative "../lib/query_helpers"

FakeTextStore = Struct.new(:rows) do
  def text_search_any(_queries, limit:, phrase:)
    raise "expected search limit" unless limit == 200
    raise "expected tokenized search" if phrase

    rows.map(&:dup)
  end
end

def with_sqlite_store(path_config, _store_cache = nil)
  yield(path_config.store)
end

def assert_equal(expected, actual)
  raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

path = OpenStruct.new(
  name: "docs",
  db_file: "docs.sqlite",
  db_table: "chunks",
  url: nil,
  store: FakeTextStore.new([
    { "path" => "docs/a.md", "chunk" => 0, "text" => "alpha", "score" => 12.5 },
  ])
)

entries = retrieve_by_text([path], "alpha", top_n: 10, parallel: false)
assert_equal 12.5, entries.first["score"]

high_score_path = OpenStruct.new(
  name: "high",
  db_file: "high.sqlite",
  db_table: "chunks",
  url: nil,
  store: FakeTextStore.new([
    { "path" => "high/first.md", "chunk" => 0, "text" => "alpha", "score" => 1000.0 },
    { "path" => "high/second.md", "chunk" => 0, "text" => "alpha", "score" => 900.0 },
  ])
)
low_score_path = OpenStruct.new(
  name: "low",
  db_file: "low.sqlite",
  db_table: "chunks",
  url: nil,
  store: FakeTextStore.new([
    { "path" => "low/first.md", "chunk" => 0, "text" => "alpha", "score" => 0.001 },
  ])
)
cross_table_entries = retrieve_by_text([high_score_path, low_score_path], "alpha", top_n: 10, parallel: false)
top_two = QueryHelpers.top_n_by_score(cross_table_entries, 2)
assert_equal ["high/first.md", "low/first.md"].sort, top_two.map { |item| item["path"] }.sort

text_lists = QueryHelpers.text_fusion_lists([
  { "path" => "docs/high.md", "chunk" => 0, "lookup" => "high", "score" => 100.0 },
  { "path" => "docs/low.md", "chunk" => 0, "lookup" => "low", "score" => 0.001 },
])
fused = QueryHelpers.fuse_entries_with_weighted_rrf(text_lists)
assert_equal [1.0, 1.0], fused.map { |item| item["score"] }

hybrid = QueryHelpers.fuse_entries_with_weighted_rrf(
  [
    {
      name: "embedding",
      weight: 1.0,
      entries: [
        { "path" => "docs/vector.md", "chunk" => 0, "score" => 0.9 },
        { "path" => "docs/shared.md", "chunk" => 0, "score" => 0.89 },
        { "path" => "docs/weak.md", "chunk" => 0, "score" => 0.1 },
      ],
    },
    *QueryHelpers.text_fusion_lists([
      { "path" => "docs/shared.md", "chunk" => 0, "lookup" => "docs", "score" => 5.0 },
      { "path" => "docs/text.md", "chunk" => 0, "lookup" => "docs", "score" => 1.0 },
    ]),
  ]
)
assert_equal "docs/shared.md", hybrid.first["path"]

puts "retriever_test: passed"
