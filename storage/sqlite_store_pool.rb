require "thread"

module SimpleRag
  class SqliteStorePool
    def initialize(factory, max_per_path:)
      @factory = factory
      @max_per_path = max_per_path
      @available = Hash.new { |hash, key| hash[key] = [] }
      @created = Hash.new(0)
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @closed = false
    end

    def with(path)
      key = [path.db_file.to_s, path.db_table.to_s]
      store = checkout(key, path)
      reusable = false
      begin
        result = yield store
        reusable = true
        result
      ensure
        reusable ? checkin(key, store) : discard(key, store)
      end
    end

    def close
      stores = @mutex.synchronize do
        @closed = true
        pooled = @available.values.flatten
        @available.clear
        @condition.broadcast
        pooled
      end
      stores.each { |store| store.close if store.respond_to?(:close) }
    end

    private

    def checkout(key, path)
      @mutex.synchronize do
        loop do
          raise IOError, "SQLite store pool is closed" if @closed
          return @available[key].pop unless @available[key].empty?
          if @created[key] < @max_per_path
            @created[key] += 1
            break
          end
          @condition.wait(@mutex)
        end
      end
      # Opening a database must not serialize checkouts for other indexes.
      opened = false
      begin
        store = @factory.call(path)
        opened = true
        store
      ensure
        release_slot(key) unless opened
      end
    end

    def checkin(key, store)
      retained = @mutex.synchronize do
        unless @closed
          @available[key] << store
          @condition.broadcast
          true
        end
      end
      discard(key, store) unless retained
    end

    def discard(key, store)
      store.close if store.respond_to?(:close)
    ensure
      release_slot(key)
    end

    def release_slot(key)
      @mutex.synchronize do
        @created[key] -= 1
        @condition.broadcast
      end
    end
  end
end
