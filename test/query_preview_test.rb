require_relative "../lib/query_helpers"

class QueryPreviewTest
  def test_matching_paragraph_is_whole_and_marks_omissions
    text = "Overview.\n\nBackups last 30 days. Deletion is permanent.\n\nAppendix."
    expected = "...Backups last 30 days. Deletion is permanent...."
    assert_equal expected, preview(text, "backups 30", expected.length)
    assert_equal QueryHelpers.brief_text(text, max_chars: expected.length - 1), preview(text, "backups 30", expected.length - 1)
  end

  def test_ties_use_earliest_and_count_distinct_complete_terms
    text = "Backupable alpha alpha.\n\nALPHA backup.\n\nBackup alpha."
    assert_equal "...ALPHA backup....", preview(text, "ALPHA alpha backup")
    assert_equal "alpha first....", preview("alpha first.\n\nalpha second.", "alpha")
  end

  def test_oversized_best_does_not_select_a_weaker_fitting_paragraph
    text = "Overview.\n\nalpha beta #{'long ' * 30}\n\nalpha short."
    assert_equal QueryHelpers.brief_text(text, max_chars: 40), preview(text, "alpha beta", 40)
  end

  def test_fallbacks_preserve_existing_behavior
    [nil, "", "Overview.\n\nOther text."].each do |text|
      [1, 3, 4, 20, 300].each do |limit|
        ["", "!!!", "unmatched"].each do |query|
          assert_equal QueryHelpers.brief_text(text, max_chars: limit), preview(text, query, limit)
        end
      end
    end
  end

  def test_unicode_crlf_blank_lines_and_whitespace_normalization
    text = " \r\n\r\nIntro.\r\n \t\r\nCAFÉ  東京\r\n2026.\r\n\r\n "
    assert_equal "...CAFÉ 東京 2026.", preview(text, "café 東京 2026")
    assert_equal "Only one paragraph.", preview("Only one paragraph.", "one")
  end

  def test_compaction_preserves_order_schema_and_input
    files = [{path: "notes/example.md", lookup: "notes", score: 0.123456,
              matched_chunks: [{text: "Intro.\n\nBackup details."}, {text: "Other."}]}]
    before = Marshal.dump(files)
    rows = QueryHelpers.compact_file_results(files, query: "backup")
    assert_equal [:path, :file, :score, :matched_chunks], rows.first.keys
    assert_equal ["...Backup details.", "Other."], rows.first[:matched_chunks]
    assert_equal 0.1235, rows.first[:score]
    assert_equal before, Marshal.dump(files)
  end

  private

  def preview(text, query, limit = 300)
    QueryHelpers.query_brief_text(text, query: query, max_chars: limit)
  end

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end
end

if $PROGRAM_NAME == __FILE__
  QueryPreviewTest.instance_methods(false).grep(/^test_/).sort.each do |name|
    QueryPreviewTest.new.public_send(name)
    puts "#{name}: passed"
  end
end
