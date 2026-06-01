require "json"

require_relative "../readers/reader"
require_relative "../readers/journal"

class JournalReaderTest
  FIXTURE_DIR = File.join(__dir__, "fixtures", "journal")

  def test_load_filters_skipped_and_small_sections
    assert_load_chunks("sections")
  end

  def test_fenced_code_headings_do_not_start_new_entries
    assert_load_chunks("fenced_code_headings")
  end

  private

  def assert_load_chunks(name)
    expected = fixture_chunks(name)
    reader = JournalReader.new(File.join(FIXTURE_DIR, "#{name}.md"))

    assert_equal expected, reader.load.chunks
  end

  def fixture_chunks(name)
    JSON.parse(File.read(File.join(FIXTURE_DIR, "#{name}.chunks.json")))
  end

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end
end

if $PROGRAM_NAME == __FILE__
  tests = %w[
    test_load_filters_skipped_and_small_sections
    test_fenced_code_headings_do_not_start_new_entries
  ]

  tests.each do |name|
    JournalReaderTest.new.public_send(name)
    puts "#{name}: passed"
  end
end
