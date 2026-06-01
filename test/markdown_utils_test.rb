require_relative "../readers/utils/markdown_utils"

class MarkdownUtilsTest
  include MarkdownUtils

  def test_strip_markdown_removes_task_list_markers
    markdown = <<~MARKDOWN
      - [ ] pending task
      - [x] completed task
      - [X] completed uppercase task
    MARKDOWN

    expected = <<~TEXT.strip
      pending task
      completed task
      completed uppercase task
    TEXT

    assert_equal expected, strip_markdown(markdown)
  end

  def test_strip_markdown_can_preserve_heading_markers
    assert_equal "# Heading", strip_markdown("# Heading", preserve_heading_markers: true)
    assert_equal "Heading", strip_markdown("# Heading")
  end

  def test_strip_markdown_link_urls_handles_parentheses
    assert_equal "label", strip_markdown("[label](https://example.com/a_(b))")
  end

  private

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end
end

if $PROGRAM_NAME == __FILE__
  tests = %w[
    test_strip_markdown_removes_task_list_markers
    test_strip_markdown_can_preserve_heading_markers
    test_strip_markdown_link_urls_handles_parentheses
  ]

  tests.each do |name|
    MarkdownUtilsTest.new.public_send(name)
    puts "#{name}: passed"
  end
end
