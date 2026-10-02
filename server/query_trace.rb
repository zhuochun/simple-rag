require "digest"
require "fileutils"
require "json"
require "securerandom"
require "sqlite3"
require "thread"
require "time"

require_relative "../lib/simple_rag/version"

module SimpleRag
  class NullQueryTraceSession
    INSTANCE = new

    def measure(_stage)
      yield
    end

    def success(**); end
    def failure(**); end
    def retrieval_observer; nil; end
  end

  class NullQueryTraceWriter
    def start(**)
      NullQueryTraceSession::INSTANCE
    end

    def close; end
  end

  class QueryTraceWriter
    SCHEMA_VERSION = 1
    BUSY_TIMEOUT_MS = 250
    ROOT = File.expand_path("..", __dir__)
    RETRIEVAL_CODE_FILES = [
      File.join(ROOT, "lib", "config_loader.rb"),
      File.join(ROOT, "lib", "query_helpers.rb"),
      File.join(ROOT, "llm", "llm.rb"),
      File.join(ROOT, "server", "retrieval_pipeline.rb"),
      File.join(ROOT, "server", "retriever.rb"),
      File.join(ROOT, "server", "retrieval_diagnostics.rb"),
      File.join(ROOT, "server", "cache.rb"),
      __FILE__,
      File.join(ROOT, "storage", "sqlite_index.rb"),
      File.join(ROOT, "storage", "sqlite_store_pool.rb"),
    ].freeze
    INSERT_COLUMNS = %w[
      id schema_version started_at completed_at status source
      query query_hash requested_mode effective_mode paths_json top_n
      plan_json result_json result_count fallback_json error_class error_summary
      planning_ms retrieval_ms fusion_ms aggregation_ms total_ms
      app_version code_revision retrieval_code_digest config_digest
      index_fingerprint index_state
    ].freeze
    EXPECTED_COLUMNS = {
      "id" => ["TEXT", 0, 1],
      "schema_version" => ["INTEGER", 1, 0],
      "started_at" => ["TEXT", 1, 0],
      "completed_at" => ["TEXT", 1, 0],
      "status" => ["TEXT", 1, 0],
      "source" => ["TEXT", 1, 0],
      "query" => ["TEXT", 1, 0],
      "query_hash" => ["TEXT", 1, 0],
      "requested_mode" => ["TEXT", 1, 0],
      "effective_mode" => ["TEXT", 0, 0],
      "paths_json" => ["TEXT", 1, 0],
      "top_n" => ["INTEGER", 1, 0],
      "plan_json" => ["TEXT", 0, 0],
      "result_json" => ["TEXT", 0, 0],
      "result_count" => ["INTEGER", 0, 0],
      "fallback_json" => ["TEXT", 0, 0],
      "error_class" => ["TEXT", 0, 0],
      "error_summary" => ["TEXT", 0, 0],
      "planning_ms" => ["REAL", 0, 0],
      "retrieval_ms" => ["REAL", 0, 0],
      "fusion_ms" => ["REAL", 0, 0],
      "aggregation_ms" => ["REAL", 0, 0],
      "total_ms" => ["REAL", 1, 0],
      "app_version" => ["TEXT", 1, 0],
      "code_revision" => ["TEXT", 0, 0],
      "retrieval_code_digest" => ["TEXT", 1, 0],
      "config_digest" => ["TEXT", 1, 0],
      "index_fingerprint" => ["TEXT", 1, 0],
      "index_state" => ["TEXT", 1, 0],
    }.freeze
    TABLE_SQL = <<~SQL.freeze
      CREATE TABLE query_traces (
        id                 TEXT PRIMARY KEY,
        schema_version     INTEGER NOT NULL,
        started_at         TEXT NOT NULL,
        completed_at       TEXT NOT NULL,
        status             TEXT NOT NULL CHECK (status IN ('ok', 'error')),
        source             TEXT NOT NULL CHECK (source IN ('server', 'local_cli')),

        query              TEXT NOT NULL,
        query_hash         TEXT NOT NULL,
        requested_mode     TEXT NOT NULL CHECK (requested_mode IN ('q', 'q_plus')),
        effective_mode     TEXT CHECK (effective_mode IN ('q', 'q_plus')),
        paths_json         TEXT NOT NULL,
        top_n              INTEGER NOT NULL CHECK (top_n > 0),

        plan_json          TEXT,
        result_json        TEXT,
        result_count       INTEGER,
        fallback_json      TEXT,
        error_class        TEXT,
        error_summary      TEXT,

        planning_ms        REAL,
        retrieval_ms       REAL,
        fusion_ms          REAL,
        aggregation_ms     REAL,
        total_ms           REAL NOT NULL,

        app_version           TEXT NOT NULL,
        code_revision         TEXT,
        retrieval_code_digest TEXT NOT NULL,
        config_digest         TEXT NOT NULL,
        index_fingerprint     TEXT NOT NULL,
        index_state           TEXT NOT NULL
          CHECK (index_state IN ('stable', 'changed', 'unknown')),

        CHECK (
          (status = 'ok' AND result_json IS NOT NULL AND result_count IS NOT NULL
            AND error_class IS NULL AND error_summary IS NULL)
          OR
          (status = 'error' AND result_json IS NULL AND result_count IS NULL
            AND error_class IS NOT NULL AND error_summary IS NOT NULL)
        )
      )
    SQL
    INDEXES = {
      "idx_query_traces_started_at" => {
        columns: %w[started_at],
        sql: "CREATE INDEX idx_query_traces_started_at ON query_traces(started_at)",
      },
      "idx_query_traces_query_history" => {
        columns: %w[query_hash started_at],
        sql: "CREATE INDEX idx_query_traces_query_history ON query_traces(query_hash, started_at)",
      },
      "idx_query_traces_comparison_context" => {
        columns: %w[
          app_version code_revision retrieval_code_digest config_digest
          index_fingerprint index_state requested_mode
        ],
        sql: <<~SQL.strip,
          CREATE INDEX idx_query_traces_comparison_context
          ON query_traces(
            app_version,
            code_revision,
            retrieval_code_digest,
            config_digest,
            index_fingerprint,
            index_state,
            requested_mode
          )
        SQL
      },
      "idx_query_traces_status_started_at" => {
        columns: %w[status started_at],
        sql: "CREATE INDEX idx_query_traces_status_started_at ON query_traces(status, started_at)",
      },
    }.freeze
    STAGE_SUMMARIES = {
      planning: "query planning failed",
      retrieval: "retrieval failed",
      fusion: "result fusion failed",
      aggregation: "result aggregation failed",
    }.freeze

    Snapshot = Struct.new(:digest, :unknown, keyword_init: true)

    def self.build(config:, config_file:, source:, warn_io: $stderr, overhead_observer: nil)
      query_log = config.respond_to?(:query_log) ? config.query_log : nil
      return NullQueryTraceWriter.new unless query_log&.enabled

      new(
        db_file: query_log.db_file,
        config_file: config_file,
        source: source,
        warn_io: warn_io,
        overhead_observer: overhead_observer
      )
    end

    def initialize(
      db_file:,
      config_file:,
      source:,
      warn_io: $stderr,
      overhead_observer: nil,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      wall_clock: -> { Time.now.utc }
    )
      @source = source.to_s
      @warn_io = warn_io
      @overhead_observer = overhead_observer
      @clock = clock
      @wall_clock = wall_clock
      @mutex = Mutex.new
      @config_digest = Digest::SHA256.file(config_file).hexdigest
      @retrieval_code_digest = code_digest
      @code_revision = read_code_revision

      FileUtils.mkdir_p(File.dirname(db_file))
      @db = SQLite3::Database.new(db_file)
      @db.busy_timeout(BUSY_TIMEOUT_MS)
      initialize_schema!
      configure_database!
      placeholders = (["?"] * INSERT_COLUMNS.length).join(", ")
      @insert_sql = <<~SQL
        INSERT INTO query_traces (#{INSERT_COLUMNS.join(", ")})
        VALUES (#{placeholders})
      SQL
    rescue
      @db&.close
      raise
    end

    def start(query:, requested_mode:, lookup_paths:, top_n:, started_at:, started_monotonic:)
      trace_started = clock
      id = SecureRandom.uuid
      before_snapshot = capture_index_snapshot(lookup_paths)
      QueryTraceSession.new(
        writer: self,
        id: id,
        query: query,
        requested_mode: requested_mode,
        lookup_paths: lookup_paths,
        top_n: top_n,
        started_at: started_at,
        started_monotonic: started_monotonic,
        before_snapshot: before_snapshot,
        start_overhead_seconds: clock - trace_started
      )
    rescue => error
      warn_write_failure("unavailable", error)
      NullQueryTraceSession::INSTANCE
    end

    def close
      @mutex.synchronize do
        @db&.close
        @db = nil
      end
    end

    def clock
      @clock.call
    end

    def wall_time
      @wall_clock.call
    end

    def capture_index_snapshot(lookup_paths)
      unknown = false
      state = Array(lookup_paths).map do |path|
        database, database_unknown = file_state(path.db_file, optional: false)
        wal, wal_unknown = file_state("#{path.db_file}-wal", optional: true)
        unknown ||= database_unknown || wal_unknown
        {
          "lookup" => path.name.to_s,
          "table" => path.db_table.to_s,
          "database" => database,
          "wal" => wal,
        }
      end
      Snapshot.new(
        digest: Digest::SHA256.hexdigest(JSON.generate(state)),
        unknown: unknown
      )
    rescue => error
      Snapshot.new(
        digest: Digest::SHA256.hexdigest("index-metadata-error:#{error.class.name}"),
        unknown: true
      )
    end

    def persist_success(session, plan:, result:, effective_mode:, fallback:, fallback_error:, attempted_expansion:)
      persist_safely(session.id) do
        total_started = clock
        projection_started = clock
        fallback_trace = fallback_projection(fallback, fallback_error)
        plan_trace = plan_projection(plan, attempted_expansion, fallback_trace)
        plan_trace["retrieval"] = session.retrieval_details if session.retrieval_details
        result_trace = result_projection(result, fallback_trace)
        projection_ms = overhead_ms(projection_started)

        serialization_started = clock
        plan_json = JSON.generate(plan_trace)
        result_json = JSON.generate(result_trace)
        fallback_json = fallback_trace ? JSON.generate(fallback_trace) : nil
        serialization_ms = overhead_ms(serialization_started)

        record = session.base_record(effective_mode: effective_mode)
        record.merge!(
          "status" => "ok",
          "plan_json" => plan_json,
          "result_json" => result_json,
          "result_count" => result[:count],
          "fallback_json" => fallback_json,
          "error_class" => nil,
          "error_summary" => nil
        )
        insertion_started = clock
        insert_record(record)
        insertion_ms = overhead_ms(insertion_started)
        observe_overhead(
          projection_ms: projection_ms,
          serialization_ms: serialization_ms,
          insertion_ms: insertion_ms,
          total_ms: overhead_ms(total_started)
        )
      end
    end

    def persist_failure(session, error:, plan:, effective_mode:, attempted_expansion:)
      persist_safely(session.id) do
        total_started = clock
        projection_started = clock
        plan_trace = plan || attempted_expansion ? plan_projection(plan, attempted_expansion, nil) : nil
        plan_trace["retrieval"] = session.retrieval_details if plan_trace && session.retrieval_details
        projection_ms = overhead_ms(projection_started)

        serialization_started = clock
        plan_json = plan_trace ? JSON.generate(plan_trace) : nil
        serialization_ms = overhead_ms(serialization_started)

        record = session.base_record(effective_mode: effective_mode)
        record.merge!(
          "status" => "error",
          "plan_json" => plan_json,
          "result_json" => nil,
          "result_count" => nil,
          "fallback_json" => nil,
          "error_class" => error.class.name,
          "error_summary" => safe_error_summary(session.failure_stage)
        )
        insertion_started = clock
        insert_record(record)
        insertion_ms = overhead_ms(insertion_started)
        observe_overhead(
          projection_ms: projection_ms,
          serialization_ms: serialization_ms,
          insertion_ms: insertion_ms,
          total_ms: overhead_ms(total_started)
        )
      end
    end

    def comparison_context
      {
        "app_version" => SimpleRag::VERSION,
        "code_revision" => @code_revision,
        "retrieval_code_digest" => @retrieval_code_digest,
        "config_digest" => @config_digest,
      }
    end

    def source
      @source
    end

    private

    def configure_database!
      @db.execute("PRAGMA journal_mode = WAL")
      @db.execute("PRAGMA foreign_keys = ON")
      @db.execute("PRAGMA synchronous = NORMAL")
    end

    def initialize_schema!
      version = @db.get_first_value("PRAGMA user_version").to_i
      objects = application_objects
      if version.zero? && objects.empty?
        @db.transaction
        @db.execute(TABLE_SQL.sub(/\ACREATE TABLE /, "CREATE TABLE IF NOT EXISTS "))
        INDEXES.each_value do |index|
          @db.execute(index[:sql].sub(/\ACREATE INDEX /, "CREATE INDEX IF NOT EXISTS "))
        end
        @db.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        @db.commit
      elsif version != SCHEMA_VERSION
        raise RuntimeError, "Unsupported query trace schema version: #{version}"
      end
      validate_schema!
    rescue
      @db.rollback rescue nil
      raise
    end

    def validate_schema!
      objects = application_objects
      expected_objects = ["query_traces"] + INDEXES.keys
      unexpected = objects - expected_objects
      missing = expected_objects - objects
      unless unexpected.empty? && missing.empty?
        raise RuntimeError, "Query trace schema objects do not match version #{SCHEMA_VERSION}"
      end

      columns = @db.execute("PRAGMA table_info(query_traces)")
      actual_columns = columns.to_h do |row|
        [row[1].to_s, [row[2].to_s.upcase, row[3].to_i, row[5].to_i]]
      end
      unless actual_columns == EXPECTED_COLUMNS
        raise RuntimeError, "Query trace table columns do not match version #{SCHEMA_VERSION}"
      end

      table_sql = @db.get_first_value(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'query_traces'"
      )
      unless normalize_sql(table_sql) == normalize_sql(TABLE_SQL)
        raise RuntimeError, "Query trace table constraints do not match version #{SCHEMA_VERSION}"
      end

      INDEXES.each do |name, expected|
        index_row = @db.execute("PRAGMA index_list(query_traces)").find { |row| row[1].to_s == name }
        unless index_row && index_row[2].to_i.zero? && index_row[4].to_i.zero?
          raise RuntimeError, "Query trace index #{name} does not match version #{SCHEMA_VERSION}"
        end
        columns = @db.execute("PRAGMA index_info(#{quote_string(name)})").map { |row| row[2].to_s }
        unless columns == expected[:columns]
          raise RuntimeError, "Query trace index #{name} does not match version #{SCHEMA_VERSION}"
        end
        index_sql = @db.get_first_value(
          "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?",
          name
        )
        unless normalize_sql(index_sql) == normalize_sql(expected[:sql])
          raise RuntimeError, "Query trace index #{name} does not match version #{SCHEMA_VERSION}"
        end
      end
    end

    def application_objects
      @db.execute(<<~SQL).map { |row| row[0].to_s }
        SELECT name
        FROM sqlite_master
        WHERE name NOT LIKE 'sqlite_%'
          AND type IN ('table', 'index', 'view', 'trigger')
        ORDER BY name
      SQL
    end

    def quote_string(value)
      "'#{value.to_s.gsub("'", "''")}'"
    end

    def normalize_sql(sql)
      sql.to_s.downcase.gsub(/\s+/, " ").strip
    end

    def file_state(path, optional:)
      return [{ "state" => optional ? "absent" : "missing" }, !optional] unless File.exist?(path)

      stat = File.stat(path)
      [{
        "state" => "present",
        "size" => stat.size,
        "mtime" => stat.mtime.to_r.to_s,
      }, false]
    rescue => error
      [{ "state" => "error", "class" => error.class.name }, true]
    end

    def persist_safely(id)
      yield
    rescue => error
      warn_write_failure(id, error)
    end

    def warn_write_failure(id, error)
      @warn_io.puts("Query trace #{id} write failed (#{error.class.name})")
    rescue
      nil
    end

    def insert_record(record)
      complete = comparison_context.merge(record)
      values = INSERT_COLUMNS.map { |column| complete[column] }
      @mutex.synchronize do
        @db.transaction
        statement = @db.prepare(@insert_sql)
        begin
          statement.execute(*values).close
        ensure
          statement.close rescue nil
        end
        @db.commit
      rescue
        @db.rollback rescue nil
        raise
      end
    end

    def plan_projection(plan, attempted_expansion, fallback_trace)
      {
        "effective" => plan && {
          "original_query" => plan.original_query,
          "semantic_rewrite" => plan.semantic_rewrite,
          "keyword_variants" => Array(plan.keyword_variants),
          "lists" => Array(plan.lists).map do |list|
            {
              "name" => list[:name],
              "backend" => list[:backend],
              "query_type" => list[:query_type],
              "query" => trace_value(list[:query]),
              "phrase" => !!list[:phrase],
              "weight" => list[:weight].to_f,
            }
          end,
        },
        "attempted_expansion" => attempted_expansion && {
          "semantic_rewrite" => attempted_expansion[:semantic_rewrite],
          "keyword_variants" => Array(attempted_expansion[:keyword_variants]),
          "reason" => fallback_trace&.fetch("reason", "expansion_failed"),
          "error_class" => fallback_trace&.fetch("error_class", nil),
          "error_summary" => fallback_trace&.fetch("error_summary", safe_error_summary(:planning)),
        },
      }
    end

    def result_projection(result, fallback_trace)
      projected = trace_value(result)
      projected["fallback"] = fallback_trace if projected.key?("fallback")
      projected
    end

    def fallback_projection(fallback, error)
      return nil unless fallback

      {
        "reason" => fallback[:reason].to_s,
        "failure_stage" => "planning",
        "error_class" => (error || RuntimeError.new).class.name,
        "error_summary" => safe_error_summary(:planning),
      }
    end

    def safe_error_summary(stage)
      STAGE_SUMMARIES.fetch(stage&.to_sym, "query retrieval failed")[0, 256]
    end

    def overhead_ms(started)
      ((clock - started) * 1000.0).round(3)
    end

    def observe_overhead(sample)
      @overhead_observer&.call(sample)
    rescue => error
      warn_write_failure("overhead-observer", error)
    end

    def trace_value(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), out| out[key.to_s] = trace_value(item) }
      when Array
        value.map { |item| trace_value(item) }
      else
        value
      end
    end

    def code_digest
      digest = Digest::SHA256.new
      RETRIEVAL_CODE_FILES.each do |file|
        digest << file.sub("#{ROOT}#{File::SEPARATOR}", "").tr("\\", "/")
        digest << "\0"
        digest << File.binread(file)
        digest << "\0"
      end
      digest.hexdigest
    end

    def read_code_revision
      git_dir = resolve_git_dir
      return nil unless git_dir

      head = File.read(File.join(git_dir, "HEAD"), encoding: "UTF-8").strip
      return head if head.match?(/\A[0-9a-f]{40}\z/i)
      return nil unless head.start_with?("ref: ")

      ref = head.delete_prefix("ref: ").strip
      loose_ref = File.join(git_dir, ref.tr("/", File::SEPARATOR))
      return File.read(loose_ref, encoding: "UTF-8").strip if File.file?(loose_ref)

      packed = File.join(git_dir, "packed-refs")
      return nil unless File.file?(packed)

      File.foreach(packed, encoding: "UTF-8") do |line|
        revision, name = line.strip.split(" ", 2)
        return revision if name == ref
      end
      nil
    rescue SystemCallError
      nil
    end

    def resolve_git_dir
      marker = File.join(ROOT, ".git")
      return marker if File.directory?(marker)
      return nil unless File.file?(marker)

      content = File.read(marker, encoding: "UTF-8").strip
      return nil unless content.start_with?("gitdir: ")

      File.expand_path(content.delete_prefix("gitdir: ").strip, ROOT)
    rescue SystemCallError
      nil
    end
  end

  class QueryTraceSession
    attr_reader :id, :failure_stage, :retrieval_details

    def initialize(
      writer:,
      id:,
      query:,
      requested_mode:,
      lookup_paths:,
      top_n:,
      started_at:,
      started_monotonic:,
      before_snapshot:,
      start_overhead_seconds:
    )
      @writer = writer
      @id = id
      @query = query
      @requested_mode = requested_mode
      @lookup_paths = lookup_paths
      @top_n = top_n
      @started_at = started_at
      @started_monotonic = started_monotonic
      @before_snapshot = before_snapshot
      @start_overhead_seconds = start_overhead_seconds
      @timings = {}
      @failure_stage = nil
      @finished = false
    end

    def measure(stage)
      started = @writer.clock
      value = yield
      @timings[stage] = elapsed_ms(started)
      value
    rescue
      @failure_stage ||= stage
      raise
    end

    def retrieval_observer
      ->(details) { @retrieval_details = details }
    end

    def success(plan:, result:, effective_mode:, fallback: nil, fallback_error: nil, attempted_expansion: nil)
      return if finish_once?

      finalize
      @writer.persist_success(
        self,
        plan: plan,
        result: result,
        effective_mode: effective_mode,
        fallback: fallback,
        fallback_error: fallback_error,
        attempted_expansion: attempted_expansion
      )
    end

    def failure(error:, plan: nil, effective_mode: nil, attempted_expansion: nil)
      return if finish_once?

      finalize
      @writer.persist_failure(
        self,
        error: error,
        plan: plan,
        effective_mode: effective_mode,
        attempted_expansion: attempted_expansion
      )
    end

    def base_record(effective_mode:)
      {
        "id" => @id,
        "schema_version" => QueryTraceWriter::SCHEMA_VERSION,
        "started_at" => @started_at.iso8601(6),
        "completed_at" => @completed_at.iso8601(6),
        "source" => @writer.source,
        "query" => @query,
        "query_hash" => Digest::SHA256.hexdigest(@query.encode("UTF-8")),
        "requested_mode" => @requested_mode,
        "effective_mode" => effective_mode,
        "paths_json" => JSON.generate(@lookup_paths.map { |path| path.name.to_s }),
        "top_n" => @top_n,
        "planning_ms" => @timings[:planning],
        "retrieval_ms" => @timings[:retrieval],
        "fusion_ms" => @timings[:fusion],
        "aggregation_ms" => @timings[:aggregation],
        "total_ms" => @total_ms,
        "index_fingerprint" => @before_snapshot.digest,
        "index_state" => @index_state,
      }
    end

    private

    def finish_once?
      already_finished = @finished
      @finished = true
      already_finished
    end

    def finalize
      total_seconds = @writer.clock - @started_monotonic - @start_overhead_seconds
      @total_ms = ([total_seconds, 0.0].max * 1000.0).round(3)
      @completed_at = @writer.wall_time
      after_snapshot = @writer.capture_index_snapshot(@lookup_paths)
      @index_state = if @before_snapshot.unknown || after_snapshot.unknown
        "unknown"
      elsif @before_snapshot.digest == after_snapshot.digest
        "stable"
      else
        "changed"
      end
    end

    def elapsed_ms(started)
      ((@writer.clock - started) * 1000.0).round(3)
    end
  end
end
