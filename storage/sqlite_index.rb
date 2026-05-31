require "json"
require "set"
require "fileutils"
require "sqlite3"

class SqliteIndex
  TABLE_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
  VECTOR_K_DEFAULT = 512
  VECTOR_DISTANCE_METRIC = "cosine"

  attr_reader :db_file, :table

  def initialize(db_file, table)
    @db_file = db_file.to_s == ":memory:" ? ":memory:" : File.expand_path(db_file)
    @table = validate_table_name(table)
    ensure_db_dir! unless @db_file == ":memory:"

    @db = SQLite3::Database.new(@db_file)
    @db.results_as_hash = true
    @vector_error = nil
    @vector_dim_cache = nil
    @vector_dim_loaded = false
    @vector_available = setup_vector_extension
    raise RuntimeError, vector_unavailable_message unless @vector_available

    ensure_schema!
  end

  def close
    @db&.close
  end

  def transaction
    @db.transaction
    yield
    @db.commit
  rescue => e
    @db.rollback rescue nil
    raise
  end

  def upsert_chunk(item)
    row = normalize_row(item)
    @db.execute(<<~SQL, [row["path"], row["chunk"], row["hash"], row["embedding"], row["bucket"], row["text"]])
      INSERT INTO #{quoted_table} (path, chunk, hash, embedding, bucket, text)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(path, chunk) DO UPDATE SET
        hash = excluded.hash,
        embedding = excluded.embedding,
        bucket = excluded.bucket,
        text = excluded.text
    SQL

    rowid = @db.get_first_value("SELECT rowid FROM #{quoted_table} WHERE path = ? AND chunk = ?", [row["path"], row["chunk"]])
    sync_fts_row(rowid, row)
    sync_vector_row(rowid, row)
  end

  def each_item
    @db.execute("SELECT path, chunk, hash, embedding, bucket, text FROM #{quoted_table}") do |row|
      yield decode_row(row)
    end
  end

  def vector_enabled?
    @vector_available && vector_dim.to_i > 0
  end

  def vector_search(query_embedding, k = VECTOR_K_DEFAULT)
    query = parse_embedding(query_embedding)
    return [] if query.empty?

    dim = vector_dim.to_i
    return [] if dim <= 0 && row_count.zero?
    raise RuntimeError, "SQLite vector index is missing for #{@db_file} table #{@table}. Rebuild the database with run-index." if dim <= 0
    raise ArgumentError, "Vector dimension mismatch: existing=#{dim}, query=#{query.length}" if dim != query.length

    sql = <<~SQL
      SELECT i.path, i.chunk, i.hash, i.bucket, i.text, v.distance
      FROM #{quoted_vector_table} v
      JOIN #{quoted_table} i ON i.rowid = v.rowid
      WHERE v.embedding MATCH ? AND k = ?
      ORDER BY v.distance
    SQL

    @db.execute(sql, [dump_embedding(query), k.to_i]).map do |row|
      item = decode_text_row(row)
      item["distance"] = row["distance"]
      item["score"] = 1.0 - row["distance"].to_f
      item
    end
  end

  def warm_vector_index!
    return true if row_count.zero?
    raise RuntimeError, "SQLite vector index is missing for #{@db_file} table #{@table}. Rebuild the database with run-index." unless vector_enabled?

    true
  end

  def chunk_hash_lookup_for_path(path)
    lookup = {}
    @db.execute("SELECT chunk, hash FROM #{quoted_table} WHERE path = ?", [path]) do |row|
      chunk = row["chunk"].to_i
      lookup[chunk] = row["hash"]
    end
    lookup
  end

  def embeddings_for_hashes(hashes)
    keys = Array(hashes).map(&:to_s).reject(&:empty?).uniq
    return {} if keys.empty?

    out = {}
    keys.each_slice(200) do |slice|
      placeholders = Array.new(slice.length, "?").join(", ")
      @db.execute(
        "SELECT hash, embedding FROM #{quoted_table} WHERE hash IN (#{placeholders})",
        slice
      ) do |row|
        key = row["hash"]
        next if key.nil? || out.key?(key)
        begin
          out[key] = parse_embedding(row["embedding"] || row[1])
        rescue
          # Skip malformed rows; caller can regenerate the embedding.
          next
        end
      end
    end
    out
  end

  def find_chunk(path, chunk, hash: nil)
    sql = "SELECT path, chunk, hash, bucket, text FROM #{quoted_table} WHERE path = ? AND chunk = ?"
    binds = [path.to_s, chunk.to_i]
    unless hash.nil? || hash.to_s.empty?
      sql += " AND hash = ?"
      binds << hash.to_s
    end
    row = @db.get_first_row(sql, binds)
    row && decode_text_row(row)
  end

  def random_chunks(count)
    sample_size = count.to_i
    return [] if sample_size <= 0

    sample_rowids = []
    seen = 0
    @db.execute("SELECT rowid FROM #{quoted_table}") do |row|
      seen += 1
      rowid = row["rowid"] || row[0]
      if sample_rowids.length < sample_size
        sample_rowids << rowid
      else
        replacement = rand(seen)
        sample_rowids[replacement] = rowid if replacement < sample_size
      end
    end

    rows_by_rowid = {}
    sample_rowids.each_slice(200) do |slice|
      placeholders = Array.new(slice.length, "?").join(", ")
      @db.execute(
        "SELECT rowid, path, chunk, hash, bucket, text FROM #{quoted_table} WHERE rowid IN (#{placeholders})",
        slice
      ) do |row|
        rows_by_rowid[row["rowid"] || row[0]] = decode_text_row(row)
      end
    end

    sample_rowids.filter_map { |rowid| rows_by_rowid[rowid] }
  end

  def text_search_any(queries, limit: nil, phrase: false)
    terms = Array(queries).map(&:to_s).map(&:strip).reject(&:empty?).uniq
    return [] if terms.empty?

    fts_query = build_fts_query(terms, phrase: phrase)
    return [] if fts_query.empty?

    sql = <<~SQL
      SELECT i.path, i.chunk, i.hash, i.bucket, i.text, -#{quoted_fts_table}.rank AS score
      FROM #{quoted_fts_table}
      JOIN #{quoted_table} i ON i.rowid = #{quoted_fts_table}.rowid
      WHERE #{quoted_fts_table} MATCH ?
      ORDER BY #{quoted_fts_table}.rank
    SQL
    binds = [fts_query]
    if limit && limit.to_i > 0
      sql += " LIMIT ?"
      binds << limit.to_i
    end

    @db.execute(sql, binds).map { |row| decode_text_row(row) }
  end

  def delete_stale_chunks(path, valid_chunks)
    valid = valid_chunks.each_with_object(Set.new) { |chunk, set| set.add(chunk.to_i) }
    existing = @db.execute("SELECT chunk FROM #{quoted_table} WHERE path = ?", [path]).map { |r| r["chunk"].to_i }
    stale = existing.reject { |chunk| valid.include?(chunk.to_i) }
    delete_chunks(path, stale)
  end

  def delete_stale_paths(valid_paths)
    ensure_temp_keep_paths_table!
    @db.execute("DELETE FROM #{quoted_keep_paths_table}")

    Array(valid_paths).map(&:to_s).reject(&:empty?).uniq.each_slice(200) do |slice|
      placeholders = Array.new(slice.length, "(?)").join(", ")
      @db.execute("INSERT OR IGNORE INTO #{quoted_keep_paths_table}(path) VALUES #{placeholders}", slice)
    end

    stale_where = "path NOT IN (SELECT path FROM #{quoted_keep_paths_table})"
    delete_index_rows_by_where(stale_where)
    @db.execute("DELETE FROM #{quoted_table} WHERE #{stale_where}")
  end

  def row_count
    @db.get_first_value("SELECT COUNT(1) FROM #{quoted_table}").to_i
  end

  private

  def ensure_schema!
    @db.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS #{quoted_table} (
        path TEXT NOT NULL,
        chunk INTEGER NOT NULL,
        hash TEXT NOT NULL,
        embedding TEXT NOT NULL,
        bucket INTEGER,
        text TEXT,
        PRIMARY KEY(path, chunk)
      )
    SQL

    @db.execute("CREATE INDEX IF NOT EXISTS #{quoted_identifier("#{table}_hash_idx")} ON #{quoted_table}(hash)")
    ensure_meta_schema!
    ensure_fts_schema!
  end

  def normalize_row(item)
    path = item["path"] || item[:path]
    chunk = item["chunk"] || item[:chunk]
    hash = item["hash"] || item[:hash]
    embedding = item["embedding"] || item[:embedding]
    bucket = item["bucket"] || item[:bucket]
    text = item["text"] || item[:text]

    raise ArgumentError, "Missing path for sqlite upsert" if path.nil? || path.to_s.empty?
    raise ArgumentError, "Missing chunk for sqlite upsert" if chunk.nil?
    raise ArgumentError, "Missing hash for sqlite upsert" if hash.nil? || hash.to_s.empty?
    raise ArgumentError, "Missing embedding for sqlite upsert" if embedding.nil?

    {
      "path" => path,
      "chunk" => chunk.to_i,
      "hash" => hash,
      "embedding" => dump_embedding(embedding),
      "bucket" => bucket.nil? ? nil : bucket.to_i,
      "text" => text
    }
  end

  def decode_row(row)
    {
      "path" => row["path"],
      "chunk" => row["chunk"].to_i,
      "hash" => row["hash"],
      "embedding" => parse_embedding(row["embedding"]),
      "bucket" => row["bucket"],
      "text" => row["text"]
    }
  end

  def decode_text_row(row)
    {
      "path" => row["path"],
      "chunk" => row["chunk"].to_i,
      "hash" => row["hash"],
      "bucket" => row["bucket"],
      "text" => row["text"],
      "score" => row["score"]
    }
  end

  def parse_embedding(raw)
    return raw if raw.is_a?(Array)
    return [] if raw.nil? || raw.to_s.empty?

    JSON.parse(raw)
  end

  def dump_embedding(embedding)
    return embedding.to_json if embedding.is_a?(Array)
    embedding.to_s
  end

  def delete_chunks(path, chunks)
    return if chunks.empty?

    delete_index_rows_by_where_clause("path = ?", [path], chunks)

    chunks.each_slice(200) do |slice|
      placeholders = Array.new(slice.length, "?").join(", ")
      @db.execute("DELETE FROM #{quoted_table} WHERE path = ? AND chunk IN (#{placeholders})", [path, *slice])
    end
  end

  def ensure_db_dir!
    dir = File.dirname(@db_file)
    FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
  end

  def validate_table_name(table_name)
    table = table_name.to_s
    unless table.match?(TABLE_NAME_PATTERN)
      raise ArgumentError, %(Invalid sqlite table "#{table_name}". Use letters, digits, and underscores only, and start with a letter or underscore.)
    end

    table
  end

  def quoted_table
    quoted_identifier(@table)
  end

  def vector_table
    "#{@table}__vec"
  end

  def quoted_vector_table
    quoted_identifier(vector_table)
  end

  def fts_table
    "#{@table}__fts"
  end

  def quoted_fts_table
    quoted_identifier(fts_table)
  end

  def meta_table
    "#{@table}__meta"
  end

  def quoted_meta_table
    quoted_identifier(meta_table)
  end

  def setup_vector_extension
    begin
      @db.enable_load_extension(true)
    rescue
      # ignore: some sqlite3 builds disallow extension loading
    end

    begin
      require "sqlite_vec"
      SqliteVec.load(@db)
    rescue LoadError
      ext_path = default_vector_extension_path
      if !ext_path.empty?
        begin
          @db.load_extension(ext_path)
        rescue => e
          @vector_error = "load_extension failed (#{e.class}: #{e.message})"
          return false
        end
      end
    rescue => e
      @vector_error = "sqlite-vec load failed (#{e.class}: #{e.message})"
      return false
    ensure
      begin
        @db.enable_load_extension(false)
      rescue
        # ignore
      end
    end

    begin
      @db.get_first_value("SELECT vec_version()")
      true
    rescue => e
      @vector_error = "vec_version() check failed (#{e.class}: #{e.message})"
      false
    end
  end

  def default_vector_extension_path
    env_path = ENV["DOT_SQLITE_VEC_EXTENSION"].to_s.strip
    return env_path unless env_path.empty?

    vendored = File.expand_path("../vendor/sqlite-vec/vec0.dll", __dir__)
    return vendored if File.exist?(vendored)

    ""
  end

  def ensure_meta_schema!
    @db.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS #{quoted_meta_table} (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    SQL
  end

  def keep_paths_table
    "__keep_paths"
  end

  def quoted_keep_paths_table
    quoted_identifier(keep_paths_table)
  end

  def ensure_temp_keep_paths_table!
    @db.execute(<<~SQL)
      CREATE TEMP TABLE IF NOT EXISTS #{quoted_keep_paths_table} (
        path TEXT PRIMARY KEY
      )
    SQL
  end

  def ensure_fts_schema!
    @db.execute(<<~SQL)
      CREATE VIRTUAL TABLE IF NOT EXISTS #{quoted_fts_table}
      USING fts5(text)
    SQL
  rescue => e
    raise RuntimeError, "Failed to initialize SQLite FTS5 index for #{@db_file}: #{e.message}"
  end

  def sync_fts_row(rowid, row)
    return if rowid.nil?

    @db.execute(
      "INSERT OR REPLACE INTO #{quoted_fts_table}(rowid, text) VALUES(?, ?)",
      [rowid.to_i, row["text"].to_s]
    )
  end

  def vector_dim
    return @vector_dim_cache if @vector_dim_loaded

    raw = @db.get_first_value("SELECT value FROM #{quoted_meta_table} WHERE key = 'vector_dim'")
    @vector_dim_loaded = true
    if raw.nil?
      @vector_dim_cache = nil
      return nil
    end

    @vector_dim_cache = raw.to_i
  end

  def ensure_vector_table_for_dim!(dim)
    raise RuntimeError, vector_unavailable_message unless @vector_available
    raise ArgumentError, "Vector embedding must not be empty" if dim.nil? || dim.to_i <= 0

    existing = vector_dim
    if existing && existing > 0 && existing != dim.to_i
      raise ArgumentError, "Vector dimension mismatch: existing=#{existing}, new=#{dim}"
    end

    @db.execute(<<~SQL)
      CREATE VIRTUAL TABLE IF NOT EXISTS #{quoted_vector_table}
      USING vec0(embedding float[#{dim.to_i}] distance_metric=#{VECTOR_DISTANCE_METRIC})
    SQL
    @db.execute(
      "INSERT INTO #{quoted_meta_table}(key, value) VALUES('vector_dim', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [dim.to_i.to_s]
    )
    @vector_dim_cache = dim.to_i
    @vector_dim_loaded = true
    true
  rescue => e
    @vector_error = "vector index initialization failed (#{e.class}: #{e.message})"
    raise RuntimeError, @vector_error
  end

  def sync_vector_row(rowid, row)
    emb = parse_embedding(row["embedding"])
    raise ArgumentError, "Vector embedding must not be empty" if emb.empty?
    ensure_vector_table_for_dim!(emb.length)
    raise RuntimeError, "Canonical SQLite row is missing after upsert" if rowid.nil?

    @db.execute("DELETE FROM #{quoted_vector_table} WHERE rowid = ?", [rowid.to_i])
    @db.execute("INSERT INTO #{quoted_vector_table}(rowid, embedding) VALUES(?, ?)", [rowid.to_i, dump_embedding(emb)])
  rescue => e
    @vector_error = "vector row sync failed (#{e.class}: #{e.message})"
    raise RuntimeError, @vector_error
  end

  def delete_index_rows_by_where_clause(where_sql, where_binds, chunks)
    chunks.each_slice(200) do |slice|
      placeholders = Array.new(slice.length, "?").join(", ")
      rowids = @db.execute(
        "SELECT rowid FROM #{quoted_table} WHERE #{where_sql} AND chunk IN (#{placeholders})",
        [*where_binds, *slice]
      ).map { |r| r["rowid"] || r[0] }.compact
      delete_vector_rows(rowids)
      delete_fts_rows(rowids)
    end
  end

  def delete_index_rows_by_where(where_sql)
    delete_vector_rows_by_where(where_sql)
    @db.execute(
      "DELETE FROM #{quoted_fts_table} WHERE rowid IN (SELECT rowid FROM #{quoted_table} WHERE #{where_sql})"
    )
  end

  def delete_vector_rows_by_where(where_sql)
    return unless vector_enabled?

    @db.execute(
      "DELETE FROM #{quoted_vector_table} WHERE rowid IN (SELECT rowid FROM #{quoted_table} WHERE #{where_sql})"
    )
  rescue => e
    @vector_error = "vector row delete failed (#{e.class}: #{e.message})"
    raise RuntimeError, @vector_error
  end

  def delete_vector_rows(rowids)
    return if rowids.empty?
    return unless vector_enabled?

    rowids.each_slice(200) do |slice|
      placeholders = Array.new(slice.length, "?").join(", ")
      @db.execute("DELETE FROM #{quoted_vector_table} WHERE rowid IN (#{placeholders})", slice)
    end
  rescue => e
    @vector_error = "vector row delete failed (#{e.class}: #{e.message})"
    raise RuntimeError, @vector_error
  end

  def delete_fts_rows(rowids)
    return if rowids.empty?

    rowids.each_slice(200) do |slice|
      placeholders = Array.new(slice.length, "?").join(", ")
      @db.execute("DELETE FROM #{quoted_fts_table} WHERE rowid IN (#{placeholders})", slice)
    end
  end

  def quoted_identifier(identifier)
    %("#{identifier}")
  end

  def build_fts_query(terms, phrase:)
    values = if phrase
      terms
    else
      terms.flat_map { |term| term.scan(/[\p{L}\p{N}_]+/u) }.uniq
    end
    values.map { |term| %("#{term.gsub('"', '""')}") }.join(" OR ")
  end

  def vector_unavailable_message
    details = @vector_error ? " Cause: #{@vector_error}." : ""
    "sqlite vector search is unavailable for #{@db_file}. Install the sqlite-vec Ruby gem, run via `bundle exec`, or set DOT_SQLITE_VEC_EXTENSION as a fallback, then restart.#{details}"
  end
end
