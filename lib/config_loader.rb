require "json"
require "ostruct"

module ConfigLoader
  DB_FORMAT = '"sqlite_file_path@table_name"'.freeze
  TABLE_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/

  module_function

  def load_config(config_path, with_path_map: false)
    config_hash = JSON.parse(File.read(config_path))
    config = OpenStruct.new(config_hash)

    path_hashes = config_hash["paths"] || []
    config.paths = path_hashes.each_with_index.map do |path_hash, idx|
      normalize_path(OpenStruct.new(path_hash), idx + 1)
    end

    if with_path_map
      config.path_map = {}
      config.paths.each do |path|
        path.searchDefault = !!path.searchDefault
        config.path_map[path.name] = path
      end
    end

    config
  end

  def parse_db_target(raw_db, path_name)
    return [nil, nil] if raw_db.nil? || raw_db.to_s.strip.empty?

    db_target = raw_db.to_s.strip
    parts = db_target.split("@", -1)
    if parts.length != 2 || parts[0].empty? || parts[1].empty?
      raise ArgumentError, %(Invalid db for path "#{path_name}": "#{db_target}". Expected #{DB_FORMAT}.)
    end

    db_file = parts[0]
    table_name = parts[1]
    unless table_name.match?(TABLE_NAME_PATTERN)
      raise ArgumentError, %(Invalid db table for path "#{path_name}": "#{table_name}". Use letters, digits, and underscores only, and start with a letter or underscore.)
    end

    [db_file, table_name]
  end

  def normalize_path(path, fallback_idx)
    path_name = path.name || "paths[#{fallback_idx}]"
    db_file, db_table = parse_db_target(path.db, path_name)
    path.db_file = db_file
    path.db_table = db_table

    has_out = !path.out.nil? && !path.out.to_s.strip.empty?
    has_db = !db_file.nil?
    unless has_out || has_db
      raise ArgumentError, %(Path "#{path_name}" must set either "out" or "db".)
    end

    path
  end
end
