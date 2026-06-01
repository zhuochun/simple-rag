require "json"
require "ostruct"
require "tmpdir"

require_relative "../lib/config_loader"
require_relative "../lib/query_helpers"
require_relative "../server/retrieval_pipeline"

class RetrievalPipelineTest
  Path = Struct.new(:name, :db_file, :db_table, :url, :threshold, keyword_init: true)

  class FakeStore
    def initialize(vector_rows: [], text_rows: [], tracker: nil, delay: 0)
      @vector_rows = vector_rows
      @text_rows = text_rows
      @tracker = tracker
      @delay = delay
    end

    def vector_search(_embedding, _limit)
      tracked { @vector_rows.map(&:dup) }
    end

    def text_search_any(_query, limit:, phrase:)
      raise "missing BM25 limit" unless limit
      raise "expected boolean phrase flag" unless phrase == true || phrase == false

      tracked { @text_rows.map(&:dup) }
    end

    def close
    end

    private

    def tracked
      @tracker&.enter(self)
      sleep @delay if @delay > 0
      yield
    ensure
      @tracker&.leave
    end
  end

  class ConcurrencyTracker
    attr_reader :max_active, :store_ids

    def initialize
      @mutex = Mutex.new
      @active = 0
      @max_active = 0
      @store_ids = []
    end

    def enter(store)
      @mutex.synchronize do
        @active += 1
        @max_active = [@max_active, @active].max
        @store_ids << store.object_id
      end
    end

    def leave
      @mutex.synchronize { @active -= 1 }
    end
  end

  class StaticExecutor
    attr_reader :plans

    def initialize(source_lists = [], error: nil)
      @source_lists = source_lists
      @error = error
      @plans = []
    end

    def execute_plan(plan, _lookup_paths, top_n:)
      raise @error if @error
      raise "missing top_n" unless top_n

      @plans << plan
      @source_lists
    end
  end

  def test_short_and_long_query_plans
    planner = planner_with_responses("semantic rewrite", "别名, alias, API, alias, original, term")

    short = planner.build_q_plan("alpha beta")
    assert_equal ["vec:original", "bm25:phrase"], short.lists.map { |item| item[:name] }
    assert_equal 2, planner.token_count("你好，世界")

    long = planner.build_q_plan("one two three four five six")
    assert_equal ["vec:original", "bm25:original", "bm25:phrase"], long.lists.map { |item| item[:name] }

    plus = planner.build_q_plus_plan("original")
    variants = plus.lists.find { |item| item[:name] == "bm25:variants" }
    assert_equal true, variants[:phrase]
    assert_equal ["别名", "alias", "API", "term"], plus.keyword_variants
  end

  def test_q_plus_falls_back_when_expansion_fails
    planner = QueryPlanner.new(chat_fn: ->(_messages) { raise "chat unavailable" })
    executor = StaticExecutor.new
    retriever = Retriever.new(planner: planner, executor: executor)

    result = retriever.retrieve_q_plus([path("docs")], "alpha", top_n: 5)

    assert_equal "q_plus", result[:requested_mode]
    assert_equal "q", result[:mode]
    assert_equal "expansion_failed", result[:fallback][:reason]
    assert_equal ["vec:original", "bm25:phrase"], executor.plans.first.lists.map { |item| item[:name] }
  end

  def test_q_plus_falls_back_when_expansion_is_unusable
    planner = planner_with_responses("", "alpha, alpha")
    executor = StaticExecutor.new
    retriever = Retriever.new(planner: planner, executor: executor)

    result = retriever.retrieve_q_plus([path("docs")], "alpha", top_n: 5)

    assert_equal "q", result[:mode]
    assert_equal "expansion_failed", result[:fallback][:reason]
    assert_equal ["vec:original", "bm25:phrase"], executor.plans.first.lists.map { |item| item[:name] }
  end

  def test_backend_failure_is_not_hidden
    planner = planner_with_responses
    executor = StaticExecutor.new(error: RuntimeError.new("vector failed"))
    retriever = Retriever.new(planner: planner, executor: executor)

    error = assert_raises(RuntimeError) { retriever.retrieve_q([path("docs")], "alpha", top_n: 5) }
    assert_equal "vector failed", error.message
  end

  def test_q_plus_backend_failure_is_not_hidden
    planner = planner_with_responses("semantic rewrite", "alias")
    executor = StaticExecutor.new(error: RuntimeError.new("bm25 failed"))
    retriever = Retriever.new(planner: planner, executor: executor)

    error = assert_raises(RuntimeError) { retriever.retrieve_q_plus([path("docs")], "alpha", top_n: 5) }
    assert_equal "bm25 failed", error.message
  end

  def test_vector_candidates_are_ranked_globally_after_thresholds
    stores = {
      "alpha" => FakeStore.new(vector_rows: [
        row("a-low.md", 0, 0.49),
        row("a-high.md", 0, 0.80),
      ]),
      "beta" => FakeStore.new(vector_rows: [
        row("b-high.md", 0, 0.90),
        row("b-mid.md", 0, 0.70),
      ]),
    }
    executor = executor_for(stores)
    plan = QueryPlan.new(
      original_query: "alpha",
      semantic_rewrite: nil,
      keyword_variants: [],
      lists: [{ name: "vec:original", backend: "vector", query_type: "original", query: "alpha", weight: 1.2 }]
    )

    lists = executor.execute_plan(plan, [path("alpha", threshold: 0.5), path("beta")], top_n: 5)
    entries = lists.first[:entries]

    assert_equal ["b-high.md", "a-high.md", "b-mid.md"], entries.map { |item| item["path"] }
    assert_equal [1, 2, 3], entries.map { |item| item["_rank"] }
  end

  def test_bm25_lists_remain_lookup_local
    stores = {
      "alpha" => FakeStore.new(text_rows: [row("a.md", 0, 1000.0)], delay: 0.02),
      "beta" => FakeStore.new(text_rows: [row("b.md", 0, 0.001)]),
    }
    executor = executor_for(stores)
    plan = QueryPlan.new(
      original_query: "alpha",
      semantic_rewrite: nil,
      keyword_variants: [],
      lists: [{ name: "bm25:phrase", backend: "bm25", query_type: "original", query: "alpha", phrase: true, weight: 1.2 }]
    )

    lists = executor.execute_plan(plan, [path("alpha"), path("beta")], top_n: 5)

    assert_equal ["bm25:phrase:alpha", "bm25:phrase:beta"], lists.map { |item| item[:name] }
    assert_equal [1, 1], lists.map { |item| item[:entries].first["_rank"] }
  end

  def test_executor_opens_distinct_connections_for_parallel_jobs
    tracker = ConcurrencyTracker.new
    factory = lambda do |_path|
      FakeStore.new(vector_rows: [row("a.md", 0, 0.9)], text_rows: [row("a.md", 0, 2.0)], tracker: tracker, delay: 0.02)
    end
    executor = RetrievalExecutor.new(
      embedding_fn: ->(_query) { [1.0, 0.0] },
      id_fn: ->(value) { value },
      url_fn: ->(value, _base) { value },
      store_factory: factory,
      threads_max: 2
    )
    plan = QueryPlan.new(
      original_query: "alpha",
      semantic_rewrite: nil,
      keyword_variants: [],
      lists: [
        { name: "vec:original", backend: "vector", query_type: "original", query: "alpha", weight: 1.2 },
        { name: "bm25:phrase", backend: "bm25", query_type: "original", query: "alpha", phrase: true, weight: 1.2 },
      ]
    )

    executor.execute_plan(plan, [path("docs")], top_n: 5)

    assert_equal 2, tracker.store_ids.uniq.length
    assert_operator tracker.max_active, :<=, 2
    assert_operator tracker.max_active, :>, 1
  end

  def test_fusion_keeps_lookup_identity_and_penalizes_expanded_only_hits
    source_lists = [
      source_list("bm25:phrase:alpha", "bm25", "original", 1.2, [
        candidate("alpha", "shared.md", 0, 10.0, 1),
      ]),
      source_list("vec:expanded", "vector", "expanded", 0.7, [
        candidate("beta", "shared.md", 0, 0.9, 1),
      ]),
    ]

    fused = FusionEngine.new.fuse_chunk_candidates(source_lists)

    assert_equal 2, fused.length
    original = fused.find { |item| item["lookup"] == "alpha" }
    expanded = fused.find { |item| item["lookup"] == "beta" }
    assert_equal 0.05, original["boosts"]["top_rank_original"]
    assert_equal(-0.05, expanded["boosts"]["expanded_only_penalty"])
    assert_operator original["final_score"], :>, expanded["final_score"]
  end

  def test_file_aggregation_uses_only_strong_chunks_for_boosts
    weak = fused_chunk("long.md", 0, 0.20, ["bm25:phrase:docs"])
    weak_second = fused_chunk("long.md", 1, 0.19, ["vec:original"])
    strong = fused_chunk("short.md", 0, 0.60, ["bm25:phrase:docs"])
    strong_second = fused_chunk("short.md", 1, 0.55, ["vec:original"])

    files = FileAggregator.new.aggregate_files([strong, strong_second, weak, weak_second], top_n: 5)
    short = files.find { |item| item[:path] == "short.md" }
    long = files.find { |item| item[:path] == "long.md" }

    assert_equal 0.02, short[:debug][:file_boosts][:multi_chunk_evidence]
    assert_equal 0.01, short[:debug][:file_boosts][:source_list_diversity]
    assert_equal 0.0, long[:debug][:file_boosts][:multi_chunk_evidence]
    assert_equal 0.0, long[:debug][:file_boosts][:source_list_diversity]
    assert_operator short[:score], :>, long[:score]
  end

  def test_retriever_validates_public_inputs
    retriever = Retriever.new(planner: planner_with_responses, executor: StaticExecutor.new)

    assert_raises(RetrievalInputError) { retriever.retrieve_q([path("docs")], " ", top_n: 5) }
    assert_raises(RetrievalInputError) { retriever.retrieve_q([path("docs")], "alpha", top_n: 0) }
    assert_raises(RetrievalInputError) { retriever.retrieve_q([path("docs")], "alpha", top_n: 101) }
    assert_raises(RetrievalInputError) { retriever.retrieve_q([], "alpha", top_n: 5) }
  end

  def test_empty_embedding_raises_backend_failure
    executor = RetrievalExecutor.new(
      embedding_fn: ->(_query) { nil },
      id_fn: ->(value) { value },
      url_fn: ->(value, _base) { value },
      store_factory: ->(_lookup) { FakeStore.new(vector_rows: [row("a.md", 0, 0.9)]) }
    )
    plan = QueryPlan.new(
      original_query: "alpha",
      semantic_rewrite: nil,
      keyword_variants: [],
      lists: [{ name: "vec:original", backend: "vector", query_type: "original", query: "alpha", weight: 1.2 }]
    )

    error = assert_raises(RuntimeError) { executor.execute_plan(plan, [path("docs")], top_n: 5) }
    assert_equal "Embedding is empty", error.message
  end

  def test_query_helpers_resolve_lookup_paths_deduplicates_selected_names
    docs = OpenStruct.new(name: "docs", searchDefault: true)
    talks = OpenStruct.new(name: "talks", searchDefault: false)
    config = OpenStruct.new(
      paths: [docs, talks],
      path_map: {
        "docs" => docs,
        "talks" => talks,
      }
    )

    selected = QueryHelpers.resolve_lookup_paths(config, ["docs", "docs", " talks "])
    assert_equal ["docs", "talks"], selected.map(&:name)
  end

  def test_config_loader_rejects_blank_and_duplicate_lookup_names
    Dir.mktmpdir("retrieval-config-") do |dir|
      blank = File.join(dir, "blank.json")
      duplicate = File.join(dir, "duplicate.json")
      File.write(blank, JSON.generate(paths: [{ name: " ", db: "index.sqlite@chunks" }]))
      File.write(duplicate, JSON.generate(paths: [
        { name: "docs", db: "index.sqlite@chunks" },
        { name: "docs", db: "index.sqlite@other" },
      ]))

      assert_raises(ArgumentError) { ConfigLoader.load_config(blank, with_path_map: true) }
      assert_raises(ArgumentError) { ConfigLoader.load_config(duplicate, with_path_map: true) }
    end
  end

  private

  def planner_with_responses(*responses)
    queue = responses.dup
    QueryPlanner.new(chat_fn: ->(_messages) { queue.shift.to_s })
  end

  def executor_for(stores)
    RetrievalExecutor.new(
      embedding_fn: ->(_query) { [1.0, 0.0] },
      id_fn: ->(value) { value },
      url_fn: ->(value, _base) { value },
      store_factory: ->(lookup) { stores.fetch(lookup.name) }
    )
  end

  def path(name, threshold: 0.0)
    Path.new(name: name, db_file: "#{name}.sqlite", db_table: "chunks", url: nil, threshold: threshold)
  end

  def row(path, chunk, score)
    { "path" => path, "chunk" => chunk, "text" => path, "score" => score }
  end

  def source_list(name, backend, query_type, weight, entries)
    { name: name, backend: backend, query_type: query_type, weight: weight, entries: entries }
  end

  def candidate(lookup, path, chunk, score, rank)
    {
      "lookup" => lookup,
      "path" => path,
      "chunk" => chunk,
      "text" => path,
      "id" => path,
      "url" => path,
      "score" => score,
      "_rank" => rank,
    }
  end

  def fused_chunk(path, chunk, score, sources)
    evidence = sources.map do |source|
      {
        "source_list" => source,
        "backend" => source.start_with?("vec:") ? "vector" : "bm25",
        "query_type" => "original",
        "rank" => 1,
        "raw_score" => score,
        "normalized_score" => score,
        "rrf_contribution" => score,
      }
    end
    {
      "lookup" => "docs",
      "path" => path,
      "chunk" => chunk,
      "text" => path,
      "id" => path,
      "url" => path,
      "final_score" => score,
      "normalized_rrf" => score,
      "normalized_score_signal" => score,
      "boosts" => { "top_rank_original" => 0.0, "expanded_only_penalty" => 0.0 },
      "sources" => sources,
      "evidence" => evidence,
    }
  end

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

  def assert_operator(left, operator, right)
    return if left.public_send(operator, right)

    raise "Expected #{left.inspect} #{operator} #{right.inspect}"
  end

  def assert_raises(error_class)
    yield
    raise "Expected #{error_class}, but nothing was raised"
  rescue error_class => e
    e
  end
end

if $PROGRAM_NAME == __FILE__
  tests = RetrievalPipelineTest.instance_methods(false).grep(/^test_/).sort
  tests.each do |name|
    RetrievalPipelineTest.new.public_send(name)
    puts "#{name}: passed"
  end
end
