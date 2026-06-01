require "json"

require_relative "../readers/reader"
require_relative "../readers/text"

class TextReaderTest
  FIXTURE_DIR = File.join(__dir__, "fixtures", "text")

  def test_load_filters_notion_metadata_and_strips_markdown
    assert_load_chunks("notion_cleanup")
  end

  def test_heading_sections_split_and_repeat_first_h1
    assert_fixture_chunks("with_headings", 6)
  end

  def test_fenced_code_headings_do_not_split_sections
    assert_fixture_chunks("fenced_code_headings", 1000)
  end

  def test_heading_chunks_discard_small_trailing_chunk
    reader = TextReader.new("unused")
    text = "# Start\n#{tokens(198)}\n\n## Tail\none"

    assert_equal ["# Start\n#{tokens(198)}"], reader.send(:threshold_chunks, text, 200)
  end

  private

  def tokens(count)
    (1..count).map { |index| "token#{index}" }.join(" ")
  end

  def assert_load_chunks(name)
    expected = fixture_chunks(name)
    reader = TextReader.new(File.join(FIXTURE_DIR, "#{name}.md"))

    assert_equal expected, reader.load.chunks
  end

  def assert_fixture_chunks(name, max_tokens)
    text = File.read(File.join(FIXTURE_DIR, "#{name}.md"))
    expected = fixture_chunks(name)
    reader = TextReader.new(File.join(FIXTURE_DIR, "#{name}.md"))
    body = reader.send(:extract_body_without_frontmatter, text)
    filtered = reader.send(:filter_notion_lines, body)

    actual = reader.send(:build_index_chunks, filtered, max_tokens)

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
    test_load_filters_notion_metadata_and_strips_markdown
    test_heading_sections_split_and_repeat_first_h1
    test_fenced_code_headings_do_not_split_sections
    test_heading_chunks_discard_small_trailing_chunk
  ]

  tests.each do |name|
    TextReaderTest.new.public_send(name)
    puts "#{name}: passed"
  end
end
