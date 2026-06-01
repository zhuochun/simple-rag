require_relative "../readers/utils/chunk_utils"

class ChunkUtilsTest
  include ChunkUtils

  def test_split_discards_trailing_chunk_below_five_percent_of_max
    text = "#{tokens(99)}\n\n#{tokens(4)}"

    assert_equal [tokens(99)], split_chunk_by_tokens(text, 100)
  end

  def test_split_keeps_trailing_chunk_at_five_percent_of_max
    text = "#{tokens(99)}\n\n#{tokens(5)}"

    assert_equal [tokens(99), tokens(5)], split_chunk_by_tokens(text, 100)
  end

  def test_split_carries_leading_context_into_oversized_paragraph
    title = tokens(10)
    text = "#{title}\n\n#{tokens(190)}"

    chunks = split_chunk_by_tokens(text, 100)

    refute_equal title, chunks.first
    assert chunks.first.start_with?("#{title}\n\n")
    assert chunks.all? { |chunk| count_tokens(chunk) <= 100 }
    assert_equal count_tokens(text), chunks.sum { |chunk| count_tokens(chunk) }
  end

  private

  def tokens(count)
    (1..count).map { |index| "token#{index}" }.join(" ")
  end

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

  def refute_equal(unexpected, actual)
    raise "Did not expect #{unexpected.inspect}" if unexpected == actual
  end

  def assert(value)
    raise "Expected truthy value" unless value
  end
end

if $PROGRAM_NAME == __FILE__
  tests = %w[
    test_split_discards_trailing_chunk_below_five_percent_of_max
    test_split_keeps_trailing_chunk_at_five_percent_of_max
    test_split_carries_leading_context_into_oversized_paragraph
  ]

  tests.each do |name|
    ChunkUtilsTest.new.public_send(name)
    puts "#{name}: passed"
  end
end
