require 'json'

class MemStorage
  def initialize
    @storage = {}
  end

  # Load or create a table from a JSON line file
  def load_or_create(table, filepath)
    @storage[table] ||= {}
    File.readlines(filepath).each do |line|
      data = JSON.parse(line)
      @storage[table][data['id']] = data
    end
  rescue Errno::ENOENT
    puts "File not found: #{filepath}"
  end

  # Add an entry to a specific table
  def add(table, entryid, entry)
    @storage[table] ||= {}
    @storage[table][entryid] = entry
  end

  # Get an entry by ID from a specific table
  def get(table, entryid)
    @storage.dig(table, entryid)
  end

  # Locate an entry across all tables
  def locate(entryid)
    @storage.each do |table, entries|
      return { table: table, entry: entries[entryid] } if entries.has_key?(entryid)
    end
    nil
  end

  # Scan a table and apply a lambda to each entry
  def scan(table)
    if block_given?
      @storage[table]&.each do |entryid, entry|
        yield entryid, entry
      end
    else
      raise ArgumentError, "No block given"
    end
  end
end
