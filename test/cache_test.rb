require_relative "../server/cache"

cache = MemCache.new(max_size: 2)
calls = 0
loader = lambda do |key|
  calls += 1
  key.upcase
end

raise "cache miss" unless cache.get_or_set("a", loader) == "A"
raise "cache should reuse stored value" unless cache.get_or_set("a", loader) == "A"
cache.get_or_set("b", loader)
cache.get_or_set("c", loader)
raise "cache should evict oldest value" unless cache.get("a").nil?
raise "unexpected loader count: #{calls}" unless calls == 3

puts "cache_test: passed"
