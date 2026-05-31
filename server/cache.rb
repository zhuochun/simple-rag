require "digest"
require "thread"

class MemCache
    DEFAULT_MAX_SIZE = 256

    def initialize(max_size: DEFAULT_MAX_SIZE)
        @data = {}
        @max_size = max_size.to_i
        @mutex = Mutex.new
    end

    def set(data, val)
        hash = digest(data)
        @mutex.synchronize { store(hash, val) }
    end

    def get(data)
        hash = digest(data)
        @mutex.synchronize { @data[hash] }
    end

    def get_or_set(data, fn)
        hash = digest(data)
        cached = @mutex.synchronize { @data[hash] if @data.key?(hash) }
        return cached unless cached.nil?

        val = fn.call(data)
        @mutex.synchronize { store(hash, val) }
        val
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
