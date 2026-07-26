require "json"
require "ostruct"
require "stringio"
require "tmpdir"

require_relative "../lib/config_loader"
require_relative "../server/retriever"
require_relative "test_assertions"

class QueryTraceTest
  include TestAssertions

  class StaticExecutor
    attr_reader :closed

    def initialize(error: nil)
      @error = error
    end

    def execute_plan(_plan, _lookup_paths, top_n:)
      raise @error if @error
      raise "unexpected top_n" unless top_n.positive?

      []
    end

    def close
      @closed = true
    end
  end

  def test_query_log_configuration_is_opt_in_and_strict
    Dir.mktmpdir("query-trace-config-") do |dir|
      index_file = File.join(dir, "index.sqlite")
      File.binwrite(index_file, "")

      disabled = load_config(dir, index_file, nil)
      assert_equal false, disabled.query_log.enabled
      assert_equal nil, disabled.query_log.db_file

      relative = load_config(
        dir,
        index_file,
        { enabled: true, db: File.join("logs", "queries.sqlite") }
      )
      assert_equal File.join(dir, "logs", "queries.sqlite"), relative.query_log.db_file

      [
        true,
        { enabled: "true", db: "queries.sqlite" },
        { enabled: true },
        { enabled: true, db: 42 },
        { enabled: false, unknown: true },
      ].each do |query_log|
        assert_raises(ArgumentError) { load_config(dir, index_file, query_log) }
      end

      error = assert_raises(ArgumentError) do
        load_config(dir, index_file, { enabled: true, db: index_file })
      end
      assert_includes error.message, "must differ from retrieval index"
    end
  end

  def test_trace_store_creates_only_versioned_query_trace_schema
    with_writer do |writer, trace_file, _config, _path|
      writer.close
      db = SQLite3::Database.new(trace_file)
      assert_equal 1, db.get_first_value("PRAGMA user_version")
      objects = db.execute(<<~SQL).map { |row| row[0] }
        SELECT name
        FROM sqlite_master
        WHERE name NOT LIKE 'sqlite_%'
        ORDER BY name
      SQL
      assert_equal(
        %w[
          idx_query_traces_comparison_context
          idx_query_traces_query_history
          idx_query_traces_started_at
          idx_query_traces_status_started_at
          query_traces
        ],
        objects
      )
      assert_equal false, objects.include?("query_evaluations")
      db.close
    end
  end

  def test_trace_store_rejects_incompatible_existing_schema
    Dir.mktmpdir("query-trace-schema-") do |dir|
      index_file = File.join(dir, "index.sqlite")
      trace_file = File.join(dir, "traces.sqlite")
      File.binwrite(index_file, "")
      db = SQLite3::Database.new(trace_file)
      db.execute("CREATE TABLE query_traces (id TEXT PRIMARY KEY)")
      db.execute("PRAGMA user_version = 1")
      db.close
      config, = configured_trace(dir, index_file, trace_file)

      error = assert_raises(RuntimeError) do
        SimpleRag::QueryTraceWriter.build(
          config: config,
          config_file: File.join(dir, "config.json"),
          source: "server"
        )
      end
      assert_includes error.message, "schema objects do not match"
    end
  end

  def test_trace_store_rejects_version_one_schema_with_extra_constraint
    Dir.mktmpdir("query-trace-extra-constraint-") do |dir|
      index_file = File.join(dir, "index.sqlite")
      trace_file = File.join(dir, "traces.sqlite")
      File.binwrite(index_file, "")
      db = SQLite3::Database.new(trace_file)
      restrictive_sql = SimpleRag::QueryTraceWriter::TABLE_SQL.sub(
        /\n\)\s*\z/,
        ",\n  CHECK (query <> 'alpha')\n)"
      )
      db.execute(restrictive_sql)
      SimpleRag::QueryTraceWriter::INDEXES.each_value { |index| db.execute(index[:sql]) }
      db.execute("PRAGMA user_version = 1")
      db.close
      config, = configured_trace(dir, index_file, trace_file)

      error = assert_raises(RuntimeError) do
        SimpleRag::QueryTraceWriter.build(
          config: config,
          config_file: File.join(dir, "config.json"),
          source: "server"
        )
      end
      assert_includes error.message, "constraints do not match"

      db = SQLite3::Database.new(trace_file)
      stored_sql = db.get_first_value(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'query_traces'"
      )
      db.close
      assert_includes stored_sql, "query <> 'alpha'"
    end
  end

  def test_standard_query_records_plan_result_timings_and_context
    with_writer do |writer, trace_file, _config, path|
      retriever = Retriever.new(
        planner: QueryPlanner.new(chat_fn: ->(*) { raise "q should not use chat" }),
        executor: StaticExecutor.new,
        trace_writer: writer
      )

      result = retriever.retrieve_q([path], "  alpha   beta  ", top_n: 5)
      assert_equal "alpha beta", result[:query]
      retriever.close

      row = trace_rows(trace_file).fetch(0)
      assert_equal "ok", row["status"]
      assert_equal "server", row["source"]
      assert_equal "alpha beta", row["query"]
      assert_equal "q", row["requested_mode"]
      assert_equal "q", row["effective_mode"]
      assert_equal ["docs"], JSON.parse(row["paths_json"])
      assert_equal 5, row["top_n"]
      assert_equal "stable", row["index_state"]
      assert_equal 64, row["query_hash"].length
      assert_equal 64, row["retrieval_code_digest"].length
      assert_equal 64, row["config_digest"].length
      assert_operator row["total_ms"], :>=, 0
      assert_operator row["planning_ms"], :>=, 0
      assert_operator row["retrieval_ms"], :>=, 0
      assert_operator row["fusion_ms"], :>=, 0
      assert_operator row["aggregation_ms"], :>=, 0

      plan = JSON.parse(row["plan_json"])
      assert_equal "alpha beta", plan.dig("effective", "original_query")
      assert_equal %w[vec:original bm25:phrase], plan.dig("effective", "lists").map { |item| item["name"] }
      assert_equal nil, plan["attempted_expansion"]

      traced_result = JSON.parse(row["result_json"])
      assert_equal "alpha beta", traced_result["query"]
      assert_equal [], traced_result["data"]
      assert_equal nil, traced_result["fallback"]
    end
  end

  def test_expanded_fallback_preserves_caller_error_but_sanitizes_trace
    with_writer do |writer, trace_file, _config, path|
      secret = "SECRET_PROVIDER_BODY"
      planner = QueryPlanner.new(chat_fn: ->(*) { raise "url=https://token@example.test?key=x body=#{secret}" })
      retriever = Retriever.new(
        planner: planner,
        executor: StaticExecutor.new,
        trace_writer: writer
      )

      result = retriever.retrieve_q_plus([path], "alpha", top_n: 5)
      assert_includes result.dig(:fallback, :message), secret
      retriever.close

      row = trace_rows(trace_file).fetch(0)
      assert_equal "q_plus", row["requested_mode"]
      assert_equal "q", row["effective_mode"]
      refute_includes row.values.compact.join(" "), secret

      fallback = JSON.parse(row["fallback_json"])
      assert_equal "expansion_failed", fallback["reason"]
      assert_equal "planning", fallback["failure_stage"]
      assert_equal "query planning failed", fallback["error_summary"]

      plan = JSON.parse(row["plan_json"])
      assert_equal "q", JSON.parse(row["result_json"])["mode"]
      assert_equal "query planning failed", plan.dig("attempted_expansion", "error_summary")
    end
  end

  def test_backend_failure_records_safe_error_and_preserves_original
    with_writer do |writer, trace_file, _config, path|
      secret = "SECRET_DATABASE_PATH"
      retriever = Retriever.new(
        planner: QueryPlanner.new(chat_fn: ->(*) { "" }),
        executor: StaticExecutor.new(error: RuntimeError.new("backend failed #{secret}")),
        trace_writer: writer
      )

      error = assert_raises(RuntimeError) do
        retriever.retrieve_q([path], "alpha", top_n: 5)
      end
      assert_includes error.message, secret
      retriever.close

      row = trace_rows(trace_file).fetch(0)
      assert_equal "error", row["status"]
      assert_equal "RuntimeError", row["error_class"]
      assert_equal "retrieval failed", row["error_summary"]
      assert_equal nil, row["result_json"]
      refute_includes row.values.compact.join(" "), secret
    end
  end

  def test_rejected_input_does_not_create_trace
    with_writer do |writer, trace_file, _config, path|
      retriever = Retriever.new(
        planner: QueryPlanner.new(chat_fn: ->(*) { "" }),
        executor: StaticExecutor.new,
        trace_writer: writer
      )

      assert_raises(RetrievalInputError) do
        retriever.retrieve_q([path], " ", top_n: 5)
      end
      retriever.close
      assert_equal [], trace_rows(trace_file)
    end
  end

  def test_trace_write_failure_does_not_change_successful_result
    warnings = StringIO.new
    with_writer(warn_io: warnings) do |writer, _trace_file, _config, path|
      writer.close
      retriever = Retriever.new(
        planner: QueryPlanner.new(chat_fn: ->(*) { "" }),
        executor: StaticExecutor.new,
        trace_writer: writer
      )

      result = retriever.retrieve_q([path], "alpha", top_n: 5)
      assert_equal "alpha", result[:query]
      assert_includes warnings.string, "Query trace"
      assert_includes warnings.string, "write failed"
      refute_includes warnings.string, "closed database"
    end
  end

  def test_trace_write_failure_does_not_mask_retrieval_error
    warnings = StringIO.new
    with_writer(warn_io: warnings) do |writer, _trace_file, _config, path|
      writer.close
      retriever = Retriever.new(
        planner: QueryPlanner.new(chat_fn: ->(*) { "" }),
        executor: StaticExecutor.new(error: RuntimeError.new("original retrieval failure")),
        trace_writer: writer
      )

      error = assert_raises(RuntimeError) do
        retriever.retrieve_q([path], "alpha", top_n: 5)
      end
      assert_equal "original retrieval failure", error.message
      assert_includes warnings.string, "write failed"
      refute_includes warnings.string, "closed database"
    end
  end

  def test_trace_store_serializes_concurrent_writes
    with_writer do |writer, trace_file, _config, path|
      plan = QueryPlan.new(
        original_query: "alpha",
        semantic_rewrite: nil,
        keyword_variants: [],
        lists: [{
          name: "vec:original",
          backend: "vector",
          query_type: "original",
          query: "alpha",
          phrase: false,
          weight: 1.2,
        }]
      )
      result = {
        query: "alpha",
        requested_mode: "q",
        mode: "q",
        fallback: nil,
        semantic_rewrite: nil,
        keyword_variants: [],
        count: 0,
        data: [],
      }

      threads = 12.times.map do
        Thread.new do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          session = writer.start(
            query: "alpha",
            requested_mode: "q",
            lookup_paths: [path],
            top_n: 5,
            started_at: Time.now.utc,
            started_monotonic: started
          )
          session.success(plan: plan, result: result, effective_mode: "q")
        end
      end
      threads.each(&:join)
      writer.close

      rows = trace_rows(trace_file)
      assert_equal 12, rows.length
      assert_equal 12, rows.map { |row| row["id"] }.uniq.length
    end
  end

  private

  def with_writer(warn_io: StringIO.new)
    Dir.mktmpdir("query-trace-") do |dir|
      index_file = File.join(dir, "index.sqlite")
      trace_file = File.join(dir, "traces.sqlite")
      File.binwrite(index_file, "index-state")
      config, path = configured_trace(dir, index_file, trace_file)
      writer = SimpleRag::QueryTraceWriter.build(
        config: config,
        config_file: File.join(dir, "config.json"),
        source: "server",
        warn_io: warn_io
      )
      yield writer, trace_file, config, path
    ensure
      writer&.close
    end
  end

  def configured_trace(dir, index_file, trace_file)
    config = load_config(dir, index_file, { enabled: true, db: trace_file })
    [config, config.paths.fetch(0)]
  end

  def load_config(dir, index_file, query_log)
    config_file = File.join(dir, "config.json")
    content = {
      paths: [{
        name: "docs",
        dir: dir,
        db: "#{index_file}@chunks",
        searchDefault: true,
      }],
    }
    content[:queryLog] = query_log unless query_log.nil?
    File.write(config_file, JSON.generate(content))
    ConfigLoader.load_config(config_file, with_path_map: true)
  end

  def trace_rows(path)
    db = SQLite3::Database.new(path)
    db.results_as_hash = true
    rows = db.execute("SELECT * FROM query_traces ORDER BY started_at")
    db.close
    rows
  end

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

  def assert_includes(value, expected)
    raise "Expected #{value.inspect} to include #{expected.inspect}" unless value.include?(expected)
  end

  def refute_includes(value, expected)
    raise "Expected #{value.inspect} not to include #{expected.inspect}" if value.include?(expected)
  end

  def assert_operator(left, operator, right)
    return if left.public_send(operator, right)

    raise "Expected #{left.inspect} #{operator} #{right.inspect}"
  end
end

if $PROGRAM_NAME == __FILE__
  tests = QueryTraceTest.instance_methods(false).grep(/^test_/).sort
  tests.each do |name|
    QueryTraceTest.new.public_send(name)
    puts "#{name}: passed"
  end
end
