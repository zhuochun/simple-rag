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

    def with(path, metrics: nil)
      key = [path.db_file.to_s, path.db_table.to_s]
      store = checkout(key, path, metrics)
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

    def checkout(key, path, metrics)
      started = clock if metrics
      @mutex.synchronize do
        loop do
          raise IOError, "SQLite store pool is closed" if @closed
          unless @available[key].empty?
            metrics&.merge!("connection" => "reused", "pool_wait_ms" => elapsed_ms(started), "open_ms" => 0.0)
            return @available[key].pop
          end
          if @created[key] < @max_per_path
            @created[key] += 1
            break
          end
          @condition.wait(@mutex)
        end
      end
      metrics&.merge!("connection" => "opened", "pool_wait_ms" => elapsed_ms(started))
      open_started = clock if metrics
      # Opening a database must not serialize checkouts for other indexes.
      opened = false
      begin
        store = @factory.call(path)
        opened = true
        store
      ensure
        metrics["open_ms"] = elapsed_ms(open_started) if metrics
        release_slot(key) unless opened
      end
    ensure
      metrics["pool_wait_ms"] ||= elapsed_ms(started) if metrics && started
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started)
      ((clock - started) * 1000.0).round(3)
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
