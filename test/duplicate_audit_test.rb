require "tmpdir"
require "open3"
require "rbconfig"
require_relative "../lib/duplicate_audit"

class DuplicateAuditTest
  def assert(value, message = "assertion failed")
    raise message unless value
  end

  def fixture(documents)
    Dir.mktmpdir("duplicate-audit-") do |dir|
      db_file = File.join(dir, "index.db")
      db = SQLite3::Database.new(db_file)
      db.execute("CREATE TABLE chunks(path TEXT, chunk INTEGER, hash TEXT, embedding TEXT, text TEXT)")
      documents.each do |name, chunks|
        file = File.join(dir, name)
        File.write(file, chunks.map(&:last).join("\n"))
        chunks.each_with_index do |(vector, text), index|
          db.execute("INSERT INTO chunks VALUES (?, ?, ?, ?, ?)", [file, index, Digest::SHA256.hexdigest(text), vector.to_json, text])
        end
      end
      db.close
      path = OpenStruct.new(name: "notes", dir: dir, db_file: db_file, db_table: "chunks")
      yield path, dir
    end
  end

  def audit(path, **options)
    SimpleRag::DuplicateAudit.new(paths: [path], **options).run
  end

  def test_same_document_and_topic_related_are_not_duplicates
    fixture("a.md" => [[[1, 0], "one"], [[1, 0], "two"]],
            "b.md" => [[[0.8, 0.6], "related topic"]]) do |path, _|
      assert(audit(path)[:clusters].empty?)
    end
  end

  def test_partial_quote_does_not_cover_documents
    fixture("a.md" => [[[1, 0, 0], "shared quote"], [[0, 1, 0], "unique analysis"]],
            "b.md" => [[[1, 0, 0], "shared quote"], [[0, 0, 1], "other arguments"]]) do |path, _|
      assert(audit(path)[:clusters].empty?)
      assert(audit(path, coverage: 0.4)[:clusters].length == 1)
    end
  end

  def test_character_coverage_and_one_to_one_matching
    fixture("a.md" => [[[1, 0, 0], "q"], [[0, 1, 0], "long unique body" * 30]],
            "b.md" => [[[1, 0, 0], "q"], [[0, 0, 1], "long other body" * 30]]) do |path, _|
      assert(audit(path, coverage: 0.5)[:clusters].empty?)
    end
    fixture("a.md" => Array.new(5) { [[1, 0], "quotation"] },
            "b.md" => [[[1, 0], "quotation"]]) do |path, _|
      assert(audit(path)[:clusters].empty?)
    end
  end

  def test_near_duplicates_evidence_limits_and_determinism
    fixture("a.md" => [[[1, 0], "first"], [[0, 1], "second"]],
            "b.md" => [[[0.999, 0.001], "first revised"], [[0.001, 0.999], "second revised"]],
            "c.md" => [[[1, 0], "first"], [[0, 1], "second"]]) do |path, _|
      before = Digest::SHA256.file(path.db_file).hexdigest
      first = audit(path, limit: 1, evidence: 1, brief_chars: 3)
      assert(first.to_json == audit(path, limit: 1, evidence: 1, brief_chars: 3).to_json)
      assert(first[:stats][:qualifying_pairs] == 3)
      assert(first[:stats][:truncated])
      cluster = first[:clusters].first
      assert(cluster[:members].length == 2 && cluster[:matches].length == 1)
      assert(cluster[:coverage].values.all? { |v| v[:characters] == 1.0 })
      assert(cluster[:matches].first[:chunks].all? { |c| c[:text].length <= 3 && c[:chunk].is_a?(Integer) })
      assert(Digest::SHA256.file(path.db_file).hexdigest == before, "source DB changed")
    end
  end

  def test_multihop_chain_retains_edges_without_transitive_claim
    angle = Math::PI / 9
    fixture("a.md" => [[[1, 0], "alpha"]],
            "b.md" => [[[Math.cos(angle), Math.sin(angle)], "bravo"]],
            "c.md" => [[[Math.cos(2 * angle), Math.sin(2 * angle)], "charlie"]]) do |path, _|
      report = audit(path, threshold: 0.9)
      assert(report[:clusters].map { |c| c[:members].map { |f| File.basename(f) } }.sort == [%w[a.md b.md], %w[b.md c.md]])
      assert(audit(path, threshold: 0.99)[:clusters].empty?)
    end
  end

  def test_prefix_empty_and_neighbor_cap
    fixture("a.md" => [[[1, 0], "same"]], "ab.md" => [[[1, 0], "same"]],
            "c.md" => [[[1, 0], "same"]]) do |path, dir|
      assert(audit(path, prefix: File.join(dir, "a.md"))[:stats][:documents] == 1)
      assert(audit(path, prefix: File.join(dir, "missing"))[:clusters].empty?)
      assert(audit(path, neighbors: 2)[:stats][:saturated_queries] > 0)
    end
    fixture({}) { |path, _| assert(audit(path)[:stats][:chunks] == 0) }
  end

  def test_index_diagnostics_and_invalid_vectors
    fixture("a.md" => [[[1, 0], "same"]]) do |path, dir|
      File.delete(File.join(dir, "a.md"))
      File.write(File.join(dir, "new.markdown"), "new")
      db = SQLite3::Database.new(path.db_file)
      db.execute("CREATE TABLE chunks__scan_timestamps(scope TEXT, scanned_at REAL)")
      db.execute("INSERT INTO chunks__scan_timestamps VALUES ('last_completed', 1)")
      db.close
      report = audit(path)
      assert(report[:indexes].first[:missing_sources] == 1)
      assert(report[:indexes].first[:unindexed_files] == 1)
      File.write(File.join(dir, "a.md"), "changed")
      assert(audit(path)[:indexes].first[:newer_sources] == 1)
      assert(report[:warnings].any? { |w| w.include?("mixed models cannot be detected") })
      missing = path.dup
      missing.db_file = File.join(dir, "absent.db")
      assert(audit(missing)[:indexes].first[:status] == "missing_database")
      assert(!File.exist?(missing.db_file))
      missing.db_file = path.db_file
      missing.db_table = "absent"
      assert(audit(missing)[:indexes].first[:status] == "missing_table")
    end
    [[[1, 0], [1, 0, 0]], [[1, 0], [0, 0]]].each do |left, right|
      fixture("a.md" => [[left, "one"]], "b.md" => [[right, "two"]]) do |path, _|
        error = begin
          audit(path)
          nil
        rescue ArgumentError => e
          e
        end
        assert(error && error.message.match?(/dimensions|norm/))
      end
    end
  end

  def test_overlapping_indexes_use_physical_document_identity
    fixture("a.md" => [[[1, 0], "same"]], "b.md" => [[[1, 0], "same"]]) do |path, dir|
      alias_path = path.dup
      alias_path.name = "alias"
      report = SimpleRag::DuplicateAudit.new(paths: [path, alias_path]).run
      assert(report[:stats][:documents] == 2 && report[:stats][:chunks] == 2)
      assert(report[:clusters].length == 1)
      alias_path.db_file = File.join(dir, "conflicting.db")
      FileUtils.cp(path.db_file, alias_path.db_file)
      db = SQLite3::Database.new(alias_path.db_file)
      db.execute("UPDATE chunks SET text='conflict'")
      db.close
      error = begin
        SimpleRag::DuplicateAudit.new(paths: [path, alias_path]).run
        nil
      rescue ArgumentError => e
        e
      end
      assert(error && error.message.include?("Conflicting overlapping indexes"))
    end
  end

  def test_cli_defaults_to_every_configured_collection
    fixture("a.md" => [[[1, 0], "same"]]) do |first, dir|
      fixture("b.md" => [[[1, 0], "same"]]) do |second, _|
        config = File.join(dir, "config.json")
        File.write(config, {paths: [first, second].each_with_index.map do |path, index|
          {name: "custom-#{index}", dir: path.dir, db: "#{path.db_file}@chunks", searchDefault: false}
        end}.to_json)
        command = [RbConfig.ruby, File.expand_path("../exe/run-duplicates", __dir__), "--config", config, "--format", "json"]
        out, err, status = Open3.capture3(*command)
        assert(status.success?, err)
        report = JSON.parse(out)
        assert(report["parameters"]["paths"] == %w[custom-0 custom-1])
        assert(report["clusters"].length == 1)
        out, err, status = Open3.capture3(*command, "--paths", "custom-0")
        assert(status.success? && JSON.parse(out)["clusters"].empty?, err)
      end
    end
  end

  def test_cli_json_text_path_filter_and_validation
    fixture("a.md" => [[[1, 0], "same"]], "b.md" => [[[1, 0], "same"]]) do |path, dir|
      config = File.join(dir, "config.json")
      File.write(config, {embedding: {provider: "nonexistent-paid-provider"},
        paths: [{name: "notes", dir: dir, db: "#{path.db_file}@chunks"},
                {name: "excluded", dir: dir, db: "#{dir}/missing.db@chunks"}]}.to_json)
      command = [RbConfig.ruby, File.expand_path("../exe/run-duplicates", __dir__), "--config", config]
      out, err, status = Open3.capture3(*command, "--paths", "notes", "--format", "json")
      assert(status.success?, err)
      assert(JSON.parse(out)["clusters"].length == 1)
      assert(JSON.parse(out)["indexes"].length == 1)
      out, err, status = Open3.capture3(*command, "--paths", "notes", "--format", "text")
      assert(status.success? && out.include?("#chunk=0"), err)
      [["--paths", "bad"], ["--threshold", "0"], ["--coverage", "1.1"], ["--limit", "0"], ["--neighbors", "1"]].each do |args|
        out, err, status = Open3.capture3(*command, *args)
        assert(!status.success? && out.empty? && err.include?("run-duplicates:"))
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  test = DuplicateAuditTest.new
  test.public_methods.grep(/^test_/).sort.each do |method|
    test.public_send(method)
    puts "#{method}: passed"
  end
end
