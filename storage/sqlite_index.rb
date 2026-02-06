require "json"
require "set"
require "fileutils"
require "sqlite3"

class SqliteIndex
  TABLE_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/

  attr_reader :db_file, :table

  def initialize(db_file, table)
    @db_file = File.expand_path(db_file)
    @table = validate_table_name(table)
    ensure_db_dir!

    @db = SQLite3::Database.new(@db_file)
    @db.results_as_hash = true
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

  def text_search(query, limit = nil)
    sql = "SELECT path, chunk, hash, embedding, bucket, text FROM #{quoted_table} WHERE text IS NOT NULL AND INSTR(text, ?) > 0"
    binds = [query.to_s]
    if limit && limit.to_i > 0
      sql += " LIMIT ?"
      binds << limit.to_i
    end

    @db.execute(sql, binds).map { |row| decode_row(row) }
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
    chunks.each_slice(200) do |slice|
      placeholders = Array.new(slice.length, "?").join(", ")
      @db.execute("DELETE FROM #{quoted_table} WHERE path = ? AND chunk IN (#{placeholders})", [path, *slice])
    end
  end

  def delete_paths(paths)
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

  def quoted_identifier(identifier)
    %("#{identifier}")
  end
end
