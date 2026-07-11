require "open3"
require "rbconfig"
require "json"
require "tmpdir"
require "webrick"

require_relative "../storage/sqlite_index"

class RunIndexCliTest
  EXECUTABLE = File.expand_path("../exe/run-index", __dir__)
  ROOT = File.expand_path("..", __dir__)

  def test_help_describes_bounded_workers
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, EXECUTABLE, "--help")

    assert_equal true, status.success?
    assert_equal "", stderr
    assert_equal true, stdout.include?("--workers N")
  end

  def test_invalid_worker_count_fails_before_loading_config
    stdout, _stderr, status = Open3.capture3(RbConfig.ruby, EXECUTABLE, "--workers", "0")

    assert_equal 1, status.exitstatus
    assert_equal true, stdout.include?("--workers must be > 0")
  end

  def test_process_indexes_a_real_file_and_reports_summary
    Dir.mktmpdir("run-index-cli-", __dir__) do |dir|
      notes_dir = File.join(dir, "notes")
      Dir.mkdir(notes_dir)
      File.write(File.join(notes_dir, "note.md"), "# Alpha\n\n#{'A useful indexed sentence. ' * 120}")
      db_file = File.join(dir, "index.sqlite")

      with_embedding_server do |embedding_url|
        config_file = File.join(dir, "config.json")
        File.write(config_file, JSON.generate(
          chat: { provider: "openai", url: embedding_url, model: "unused" },
          embedding: { provider: "openai", url: embedding_url, model: "test" },
          paths: [{
            name: "notes",
            reader: "text",
            threshold: 0.0,
            dir: notes_dir,
            db: "#{db_file}@chunks",
            nameMatch: "*.md",
            searchDefault: true
          }]
        ))

        stdout, stderr, status = Open3.capture3(
          { "DOT_OPENAI_KEY" => "test" },
          RbConfig.ruby,
          EXECUTABLE,
          "--non-interactive",
          "--workers",
          "1",
          config_file,
          chdir: ROOT
        )

        unless status.success?
          raise "run-index failed exit=#{status.exitstatus}\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
        end
        assert_equal "", stderr
        unless stdout.include?("notes: Match 1, Read 1 files | Create 1")
          raise "run-index summary missing from: #{stdout.inspect}"
        end
        store = SqliteIndex.new(db_file, "chunks")
        assert_equal 1, store.row_count
        store.close
      end
    end
  end

  private

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

  def with_embedding_server
    server = WEBrick::HTTPServer.new(
      BindAddress: "127.0.0.1",
      Port: 0,
      Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL),
      AccessLog: []
    )
    server.mount_proc "/embeddings" do |_request, response|
      response["Content-Type"] = "application/json"
      response.body = JSON.generate(data: [{ embedding: [1.0, 0.0] }])
    end
    thread = Thread.new { server.start }
    yield "http://127.0.0.1:#{server.config[:Port]}/embeddings"
  ensure
    server&.shutdown
    thread&.join
  end
end

if $PROGRAM_NAME == __FILE__
  test = RunIndexCliTest.new
  test.test_help_describes_bounded_workers
  puts "test_help_describes_bounded_workers: passed"
  test.test_invalid_worker_count_fails_before_loading_config
  puts "test_invalid_worker_count_fails_before_loading_config: passed"
  test.test_process_indexes_a_real_file_and_reports_summary
  puts "test_process_indexes_a_real_file_and_reports_summary: passed"
end
