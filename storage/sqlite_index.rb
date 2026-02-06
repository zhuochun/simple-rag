require "json"
require "set"
require "fileutils"
require "sqlite3"

class SqliteIndex
  TABLE_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
  VECTOR_K_DEFAULT = 512

  attr_reader :db_file, :table

  def initialize(db_file, table)
    @db_file = File.expand_path(db_file)
    @table = validate_table_name(table)
    ensure_db_dir!

    @db = SQLite3::Database.new(@db_file)
    @db.results_as_hash = true
    @vector_dim_cache = nil
    @vector_dim_loaded = false
    @vector_available = setup_vector_extension
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
    raise e
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

    sync_vector_row(row)
  end

  def list_items
    @db.execute("SELECT path, chunk, hash, embedding, bucket, text FROM #{quoted_table}").map do |row|
      decode_row(row)
    end
  end

  def each_item
    @db.execute("SELECT path, chunk, hash, embedding, bucket, text FROM #{quoted_table}") do |row|
      yield decode_row(row)
    end
  end

  def each_item_by_buckets(bucket_keys)
    keys = bucket_keys.map(&:to_i).uniq
    return if keys.empty?

    keys.each_slice(200) do |slice|
      placeholders = Array.new(slice.length, "?").join(", ")
      @db.execute(
        "SELECT path, chunk, hash, embedding, bucket, text FROM #{quoted_table} WHERE bucket IN (#{placeholders})",
        slice
      ) do |row|
        yield decode_row(row)
      end
    end
  end

  def each_item_without_bucket
    @db.execute("SELECT path, chunk, hash, embedding, bucket, text FROM #{quoted_table} WHERE bucket IS NULL") do |row|
      yield decode_row(row)
    end
  end

  def vector_enabled?
    @vector_available && vector_dim.to_i > 0
  end

  def vector_search(query_embedding, k = VECTOR_K_DEFAULT)
    return [] unless @vector_available
    ensure_vector_index_from_existing!
    return [] unless vector_enabled?

    query = parse_embedding(query_embedding)
    return [] if query.empty?
    return [] if vector_dim.to_i != query.length

    sql = <<~SQL
      SELECT i.path, i.chunk, i.hash, i.embedding, i.bucket, i.text, v.distance
      FROM #{quoted_vector_table} v
      JOIN #{quoted_table} i ON i.rowid = v.rowid
      WHERE v.embedding MATCH ? AND k = ?
      ORDER BY v.distance
    SQL

    @db.execute(sql, [dump_embedding(query), k.to_i]).map do |row|
      item = decode_row(row)
      item["distance"] = row["distance"]
      item
    end
  end

  def hash_lookup
    lookup = {}
    @db.execute("SELECT hash, embedding, bucket, text FROM #{quoted_table}") do |row|
      key = row["hash"]
      next if key.nil?

      lookup[key] = {
        "hash" => key,
        "embedding" => parse_embedding(row["embedding"]),
        "bucket" => row["bucket"],
        "text" => row["text"]
      }
    end
    lookup
  end

  def random_chunks(count)
    @db.execute(
      "SELECT path, chunk, hash, embedding, bucket, text FROM #{quoted_table} ORDER BY RANDOM() LIMIT ?",
      [count.to_i]
    ).map { |row| decode_row(row) }
  end

  def random_chunk_refs(count)
    @db.execute(
      "SELECT path, chunk FROM #{quoted_table} ORDER BY RANDOM() LIMIT ?",
      [count.to_i]
    ).map do |row|
      {
        "path" => row["path"],
        "chunk" => row["chunk"].to_i
      }
    end
  end

  def text_search(query, limit = nil)
    text_search_any([query], limit: limit)
  end

  def text_search_any(queries, limit: nil)
    terms = Array(queries).map(&:to_s).map(&:strip).reject(&:empty?).uniq
    return [] if terms.empty?

    clauses = terms.map { "INSTR(text, ?) > 0" }.join(" OR ")
    sql = "SELECT path, chunk, hash, bucket, text FROM #{quoted_table} WHERE text IS NOT NULL AND (#{clauses})"
    binds = terms
    if limit && limit.to_i > 0
      sql += " LIMIT ?"
      binds << limit.to_i
    end

    @db.execute(sql, binds).map { |row| decode_text_row(row) }
  end

  def delete_stale_chunks(path, valid_chunks)
    valid = valid_chunks.map(&:to_i).uniq
    existing = @db.execute("SELECT chunk FROM #{quoted_table} WHERE path = ?", [path]).map { |r| r["chunk"].to_i }
    stale = existing.reject { |chunk| valid.include?(chunk) }
    delete_chunks(path, stale)
  end

  def delete_stale_paths(valid_paths)
    keep = valid_paths.to_set
    existing = @db.execute("SELECT DISTINCT path FROM #{quoted_table}").map { |r| r["path"] }
    stale = existing.reject { |path| keep.include?(path) }
    delete_paths(stale)
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
    @db.execute("CREATE INDEX IF NOT EXISTS #{quoted_identifier("#{table}_bucket_idx")} ON #{quoted_table}(bucket)")
    @db.execute("CREATE INDEX IF NOT EXISTS #{quoted_identifier("#{table}_path_idx")} ON #{quoted_table}(path)")
    ensure_meta_schema!
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
      "text" => row["text"]
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

    delete_vector_rows_by_where_clause("path = ?", [path], chunks)

    chunks.each_slice(200) do |slice|
      placeholders = Array.new(slice.length, "?").join(", ")
      @db.execute("DELETE FROM #{quoted_table} WHERE path = ? AND chunk IN (#{placeholders})", [path, *slice])
    end
  end

  def delete_paths(paths)
    return if paths.empty?

    delete_vector_rows_by_paths(paths)

    paths.each_slice(100) do |slice|
      placeholders = Array.new(slice.length, "?").join(", ")
      @db.execute("DELETE FROM #{quoted_table} WHERE path IN (#{placeholders})", slice)
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

    ext_path = ENV["DOT_SQLITE_VEC_EXTENSION"]
    if ext_path && !ext_path.to_s.strip.empty?
      begin
        @db.load_extension(ext_path)
      rescue
        return false
      end
    end

    begin
      @db.get_first_value("SELECT vec_version()")
      true
    rescue
      false
    end
  end

  def ensure_meta_schema!
    @db.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS #{quoted_meta_table} (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    SQL
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
    return false unless @vector_available
    return false if dim.nil? || dim.to_i <= 0

    existing = vector_dim
    if existing && existing > 0 && existing != dim.to_i
      raise ArgumentError, "Vector dimension mismatch: existing=#{existing}, new=#{dim}"
    end

    @db.execute(<<~SQL)
      CREATE VIRTUAL TABLE IF NOT EXISTS #{quoted_vector_table}
      USING vec0(embedding float[#{dim.to_i}])
    SQL

    @db.execute(
      "INSERT INTO #{quoted_meta_table}(key, value) VALUES('vector_dim', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [dim.to_i.to_s]
    )
    @vector_dim_cache = dim.to_i
    @vector_dim_loaded = true
    true
  rescue
    @vector_available = false
    false
  end

  def ensure_vector_index_from_existing!
    return unless @vector_available
    return if vector_dim.to_i > 0

    sample = @db.get_first_row("SELECT embedding FROM #{quoted_table} LIMIT 1")
    return if sample.nil?

    sample_emb = parse_embedding(sample["embedding"] || sample[0])
    return if sample_emb.empty?
    return unless ensure_vector_table_for_dim!(sample_emb.length)

    @db.execute("SELECT rowid, embedding FROM #{quoted_table}") do |row|
      emb = parse_embedding(row["embedding"] || row[1])
      next if emb.empty?

      @db.execute(
        "INSERT OR REPLACE INTO #{quoted_vector_table}(rowid, embedding) VALUES(?, ?)",
        [(row["rowid"] || row[0]).to_i, dump_embedding(emb)]
      )
    end
  rescue
    @vector_available = false
  end

  def sync_vector_row(row)
    emb = parse_embedding(row["embedding"])
    return if emb.empty?
    return unless ensure_vector_table_for_dim!(emb.length)

    rowid = @db.get_first_value("SELECT rowid FROM #{quoted_table} WHERE path = ? AND chunk = ?", [row["path"], row["chunk"]])
    return if rowid.nil?

    @db.execute(
      "INSERT OR REPLACE INTO #{quoted_vector_table}(rowid, embedding) VALUES(?, ?)",
      [rowid.to_i, dump_embedding(emb)]
    )
  rescue
    @vector_available = false
  end

  def delete_vector_rows_by_where_clause(where_sql, where_binds, chunks)
    return unless vector_enabled?

    chunks.each_slice(200) do |slice|
      placeholders = Array.new(slice.length, "?").join(", ")
      rowids = @db.execute(
        "SELECT rowid FROM #{quoted_table} WHERE #{where_sql} AND chunk IN (#{placeholders})",
        [*where_binds, *slice]
      ).map { |r| r["rowid"] || r[0] }.compact
      delete_vector_rows(rowids)
    end
  end

  def delete_vector_rows_by_paths(paths)
    return unless vector_enabled?

    paths.each_slice(100) do |slice|
      placeholders = Array.new(slice.length, "?").join(", ")
      rowids = @db.execute(
        "SELECT rowid FROM #{quoted_table} WHERE path IN (#{placeholders})",
        slice
      ).map { |r| r["rowid"] || r[0] }.compact
      delete_vector_rows(rowids)
    end
  end

  def delete_vector_rows(rowids)
    return if rowids.empty?

    rowids.each_slice(200) do |slice|
      placeholders = Array.new(slice.length, "?").join(", ")
      @db.execute("DELETE FROM #{quoted_vector_table} WHERE rowid IN (#{placeholders})", slice)
    end
  rescue
    @vector_available = false
  end

  def quoted_identifier(identifier)
    %("#{identifier}")
  end
end
