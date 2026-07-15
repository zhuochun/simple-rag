require "tmpdir"

require_relative "../server/dismissal_store"
require_relative "test_assertions"

class DismissalStoreTest
  include TestAssertions

  def test_concurrent_dismissals_are_persisted_without_lost_updates
    Dir.mktmpdir("dismissals-", __dir__) do |dir|
      path = File.join(dir, "dismissed.txt")
      store = SimpleRag::DismissalStore.new(path)
      ids = 20.times.map { |index| "cluster-#{index}" }

      ids.map { |id| Thread.new { store.dismiss(id) } }.each(&:join)

      reloaded = SimpleRag::DismissalStore.new(path)
      assert_equal true, ids.all? { |id| reloaded.include?(id) }
    end
  end

  def test_store_without_a_file_keeps_process_local_state
    store = SimpleRag::DismissalStore.new(nil)
    store.dismiss("cluster-local")

    assert_equal true, store.include?("cluster-local")
  end

  def test_failed_persistence_does_not_commit_in_memory_state
    Dir.mktmpdir("dismissal-failure-", __dir__) do |directory_path|
      store = SimpleRag::DismissalStore.new(directory_path)

      assert_raises(SystemCallError) { store.dismiss("cluster-failed") }

      assert_equal false, store.include?("cluster-failed")
    end
  end

  private

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

end

if $PROGRAM_NAME == __FILE__
  test = DismissalStoreTest.new
  test.test_concurrent_dismissals_are_persisted_without_lost_updates
  puts "test_concurrent_dismissals_are_persisted_without_lost_updates: passed"
  test.test_store_without_a_file_keeps_process_local_state
  puts "test_store_without_a_file_keeps_process_local_state: passed"
  test.test_failed_persistence_does_not_commit_in_memory_state
  puts "test_failed_persistence_does_not_commit_in_memory_state: passed"
end
