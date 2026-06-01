require "json"

require_relative "../readers/reader"
require_relative "../readers/markdown"

class MarkdownReaderTest
  FIXTURE_DIR = File.join(__dir__, "fixtures", "markdown")

  def test_headings_within_max_stay_in_one_chunk
    assert_fixture_chunks("headings_within_max", 1000)

    reader = MarkdownReader.new(File.join(FIXTURE_DIR, "headings_within_max.md"))
    expected = fixture_chunks("headings_within_max")
    assert_equal expected, reader.load.chunks
  end

  def test_headings_split_before_cleanup_and_preserve_heading_path
    assert_fixture_chunks("with_headings", 7)
  end

  def test_oversized_heading_section_repeats_heading_path
    assert_fixture_chunks("oversized_heading", 5)
  end

  def test_no_headings_fall_back_to_token_threshold_chunks
    assert_fixture_chunks("without_headings", 4)
  end

  def test_fenced_code_headings_do_not_split_sections
    assert_fixture_chunks("fenced_code_headings", 1000)
  end

  def test_attached_heading_hashes_are_preserved
    assert_fixture_chunks("attached_heading_hashes", 1000)
  end

  def test_heading_chunks_discard_small_trailing_chunk
    reader = MarkdownReader.new("unused")
    text = "# Start\n#{tokens(199)}\n\n## Tail\none"

    assert_equal ["Start\n\n#{tokens(199)}"], reader.send(:threshold_chunks, text, 200)
  end

  private

  def tokens(count)
    (1..count).map { |index| "token#{index}" }.join(" ")
  end

  def assert_fixture_chunks(name, max_tokens)
    markdown = File.read(File.join(FIXTURE_DIR, "#{name}.md"))
    expected = fixture_chunks(name)
    reader = MarkdownReader.new(File.join(FIXTURE_DIR, "#{name}.md"))
    title, _status, body = reader.send(:extract_frontmatter_and_body, markdown)

    actual = reader.send(:build_index_chunks, title, body, max_tokens)

    assert_equal expected, actual
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
    test_headings_within_max_stay_in_one_chunk
    test_headings_split_before_cleanup_and_preserve_heading_path
    test_oversized_heading_section_repeats_heading_path
    test_no_headings_fall_back_to_token_threshold_chunks
    test_fenced_code_headings_do_not_split_sections
    test_attached_heading_hashes_are_preserved
    test_heading_chunks_discard_small_trailing_chunk
  ]

  tests.each do |name|
    MarkdownReaderTest.new.public_send(name)
    puts "#{name}: passed"
  end
end
