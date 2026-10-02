require_relative "../server/cache"
require "timeout"

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

def shared_load(value, fail: false, interrupt: false)
  cache = MemCache.new
  entered = Queue.new
  release = Queue.new
  calls = 0
  loader = lambda do |_key|
    calls += 1
    entered << true
    release.pop
    raise "provider unavailable" if fail
    value
  end
  fetch = lambda do
    cache.get_or_set("same", loader)
  rescue RuntimeError => error
    error.message
  end
  leader = Thread.new(&fetch)
  Timeout.timeout(5) { entered.pop }
  followers = Array.new(5) { Thread.new(&fetch) }
  Timeout.timeout(5) { Thread.pass until followers.all? { |thread| thread.status == "sleep" } }
  interrupt ? leader.kill : release.push(true)
  results = Timeout.timeout(5) { followers.map(&:value) }
  leader.join
  expected = interrupt ? "Cache load interrupted" : (fail ? "provider unavailable" : value)
  raise "Waiters did not share the outcome: #{results}" unless results == [expected] * 5
  raise "Expected one provider call, got #{calls}" unless calls == 1
  if fail || interrupt
    raise "Failed load poisoned cache" unless cache.get_or_set("same", ->(*) { "recovered" }) == "recovered"
  end
ensure
  release << true
  ([leader] + Array(followers)).compact.each(&:join)
end

["embedding", nil, false].each { |value| shared_load(value) }
shared_load(nil, fail: true)
shared_load(nil, interrupt: true)

cache = MemCache.new
entered = Queue.new
release = Queue.new
workers = %w[first second].map do |key|
  Thread.new do
    cache.get_or_set(key, lambda do |value|
      entered << value
      release.pop
      value
    end)
  end
end
begin
  keys = Timeout.timeout(5) { [entered.pop, entered.pop] }
  raise "Distinct keys were serialized" unless keys.sort == %w[first second]
ensure
  2.times { release << true }
  workers.each(&:join)
end
puts "cache_concurrency_test: passed"

cache = MemCache.new
events = []
2.times { cache.get_or_set("observed", ->(*) { "value" }) { |status| events << status } }
raise "Missing cache diagnostics" unless events == [:miss, :hit]
raise "Observer changed cache result" unless cache.get_or_set("observed", ->(*) { raise "unexpected load" }) { raise "observer failed" } == "value"
entered = Queue.new
release = Queue.new
leader = Thread.new { cache.get_or_set("waiting", ->(*) { entered << true; release.pop; "shared" }) }
Timeout.timeout(5) { entered.pop }
waiter = Thread.new { cache.get_or_set("waiting", ->(*) { raise "duplicate load" }) { |status| events << status } }
Timeout.timeout(5) { Thread.pass until waiter.status == "sleep" }
release << true
raise "Waiter changed result" unless Timeout.timeout(5) { waiter.value } == "shared"
leader.join
raise "Missing waiter diagnostics" unless events.last == :wait
puts "cache_diagnostics_test: passed"
