require "ostruct"
require "timeout"
require_relative "../storage/sqlite_store_pool"
require_relative "test_assertions"

class SqliteStorePoolTest
  include TestAssertions
  Store = Struct.new(:closed) do
    def close
      self.closed = true
    end
  end

  def test_closing_wakes_waiters_and_closes_borrowed_stores_on_return
    store = Store.new(false)
    pool = SimpleRag::SqliteStorePool.new(->(*) { store }, max_per_path: 1)
    path = OpenStruct.new(db_file: "one.sqlite", db_table: "chunks")
    entered = Queue.new
    release = Queue.new
    borrower = Thread.new { pool.with(path) { entered << true; release.pop } }
    Timeout.timeout(5) { entered.pop }
    waiter = Thread.new do
      pool.with(path) { "unexpected checkout" }
    rescue IOError => error
      error.message
    end
    Timeout.timeout(5) { Thread.pass until waiter.status == "sleep" }
    pool.close
    assert_equal "SQLite store pool is closed", Timeout.timeout(5) { waiter.value }
    assert_equal false, store.closed
    release << true
    Timeout.timeout(5) { borrower.join }
    assert_equal true, store.closed
    pool.close
    assert_raises(IOError) { pool.with(path) {} }
  ensure
    release << true
    borrower&.join
    waiter&.join
    pool&.close
  end

  def test_failed_open_releases_capacity_and_failed_use_discards_connection
    stores = []
    fail_open = true
    pool = SimpleRag::SqliteStorePool.new(lambda do |_path|
      if fail_open
        fail_open = false
        raise "open failed"
      end
      Store.new(false).tap { |store| stores << store }
    end, max_per_path: 1)
    path = OpenStruct.new(db_file: "one.sqlite", db_table: "chunks")
    assert_equal "open failed", assert_raises(RuntimeError) { pool.with(path) {} }.message
    error = Timeout.timeout(5) { assert_raises(RuntimeError) { pool.with(path) { raise "query failed" } } }
    assert_equal "query failed", error.message
    assert_equal true, stores.first.closed
    Timeout.timeout(5) { pool.with(path) { |store| assert_equal false, store.closed } }
    assert_equal 2, stores.length
  ensure
    pool&.close
  end

  def test_different_indexes_can_open_concurrently
    entered = Queue.new
    release = Queue.new
    pool = SimpleRag::SqliteStorePool.new(lambda do |path|
      entered << path.db_file
      release.pop
      Store.new(false)
    end, max_per_path: 1)
    workers = %w[first second].map do |name|
      Thread.new { pool.with(OpenStruct.new(db_file: name, db_table: "chunks")) {} }
    end
    names = Timeout.timeout(5) { [entered.pop, entered.pop] }
    assert_equal %w[first second], names.sort
  ensure
    2.times { release << true }
    workers&.each(&:join)
    pool&.close
  end

  private

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end
end

if $PROGRAM_NAME == __FILE__
  SqliteStorePoolTest.instance_methods(false).grep(/^test_/).sort.each do |name|
    SqliteStorePoolTest.new.public_send(name)
    puts "#{name}: passed"
  end
end
