require "digest"
require "thread"

class MemCache
    DEFAULT_MAX_SIZE = 256
    Flight = Struct.new(:condition, :owner, :done, :value, :error)
    private_constant :Flight

    def initialize(max_size: DEFAULT_MAX_SIZE)
        @data = {}
        @max_size = max_size.to_i
        @mutex = Mutex.new
        @inflight = {}
    end

    def set(data, val)
        hash = digest(data)
        @mutex.synchronize { store(hash, val) }
    end

    def get(data)
        hash = digest(data)
        @mutex.synchronize { @data[hash] }
    end

    def get_or_set(data, fn, &observer)
        cache_status = nil
        hash = digest(data)
        flight = @mutex.synchronize do
            cached = @data[hash]
            unless cached.nil?
                cache_status = :hit
                return cached
            end

            pending = @inflight[hash]
            if pending
                cache_status = :wait
                raise ThreadError, "Recursive cache load for the same key" if pending.owner == Thread.current
                pending.condition.wait(@mutex) until pending.done
                raise pending.error if pending.error
                return pending.value
            end
            @inflight[hash] = Flight.new(ConditionVariable.new, Thread.current, false)
        end
        cache_status = :miss

        begin
            val = fn.call(data)
            @mutex.synchronize do
                store(hash, val)
                flight.value = val
                flight.done = true
            end
            val
        rescue Exception => error
            # Publish failures to waiters, including non-StandardError exits,
            # then propagate the original failure to the loading caller.
            @mutex.synchronize { flight.error = error }
            raise
        ensure
            @mutex.synchronize do
                flight.error ||= RuntimeError.new("Cache load interrupted") unless flight.done
                flight.done = true
                @inflight.delete(hash)
                flight.condition.broadcast
            end
        end
    ensure
        begin
            observer&.call(cache_status) if cache_status
        rescue StandardError
            # Optional diagnostics must not change cache behavior.
            nil
        end
    end

    private

    def digest(data)
        Digest::SHA256.hexdigest(data.to_s)
    end

    def store(hash, val)
        @data.delete(hash)
        @data[hash] = val
        @data.shift while @max_size > 0 && @data.length > @max_size
        val
    end
end

CACHE = MemCache.new
