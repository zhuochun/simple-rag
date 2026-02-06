require "digest"

class MemCache
    attr_accessor :data

    def initialize
        @data = {}
    end

    def set(data, val)
        hash = Digest::SHA256.hexdigest(data)
        @data[hash] = val
    end

    def get(data)
        hash = Digest::SHA256.hexdigest(data)
        @data[hash]
    end

    def get_or_set(data, fn)
        hash = Digest::SHA256.hexdigest(data)
        return @data[hash] if @data[hash]

        STDOUT << "Set then get cache #{hash}\n"

        val = fn.call(data)
        @data[hash] = val
        return val
    end
end

CACHE = MemCache.new
