require "json"
require "digest"
require "open3"
require "rbconfig"
require "tmpdir"
require "webrick"
require_relative "../storage/sqlite_index"

class RunQueryCliTest
  ROOT = File.expand_path("..", __dir__)
  EXECUTABLE = File.join(ROOT, "exe/run-query")
  TEXT = "This guide describes backup configuration and recovery procedures.\n\nBackups are retained for 30 days. Deleted backups cannot be recovered."
  PREVIEW = "...Backups are retained for 30 days. Deleted backups cannot be recovered."

  def test_server_and_local_cli_formats_preserve_context_and_full_output
    Dir.mktmpdir("run-query-cli-", __dir__) do |dir|
      file = File.join(dir, "note.md")
      File.write(file, TEXT)
      db_file = File.join(dir, "index.sqlite")
      store = SqliteIndex.new(db_file, "chunks")
      begin
        store.upsert_chunks([{path: file, chunk: 0, hash: Digest::SHA256.hexdigest(TEXT),
                              text: TEXT, embedding: [1.0, 0.0], bucket: 1}])
      ensure
        store.close
      end
      config = File.join(dir, "config.json")
      server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: 0,
        Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL), AccessLog: [])
      url = "http://127.0.0.1:#{server.config[:Port]}"
      File.write(config, JSON.generate(
        embedding: {provider: "openai", model: "test", url: "#{url}/embeddings"},
        paths: [{name: "notes", reader: "text", dir: dir, db: "#{db_file}@chunks",
                 threshold: 0.0, searchDefault: true}]
      ))
      server.mount_proc("/embeddings") do |_request, response|
        response['Content-Type'] = 'application/json'
        response.body = JSON.generate(data: [{embedding: [1.0, 0.0]}])
      end
      chunk = {chunk: 0, text: TEXT, score: 0.8}
      full_file = {path: file, lookup: "notes", score: 0.8, anchor_chunk: chunk, matched_chunks: [chunk]}
      server.mount_proc("/health") do |_request, response|
        response['Content-Type'] = 'application/json'
        response.body = JSON.generate(config: config, configDigest: Digest::SHA256.file(config).hexdigest)
      end
      server.mount_proc("/q") do |request, response|
        raise 'CLI did not send original query' unless JSON.parse(request.body)['q'] == 'backups retained'
        response['Content-Type'] = 'application/json'
        # Selection must use the CLI user query, not a server-supplied query field.
        response.body = JSON.generate(query: 'guide configuration', data: [full_file])
      end
      thread = Thread.new { server.start }
      begin
        # A second server returns 404 for /health, forcing real local retrieval.
        fallback = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: 0,
          Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL), AccessLog: [])
        fallback_thread = Thread.new { fallback.start }
        [url, "http://127.0.0.1:#{fallback.config[:Port]}"].each do |rag_url|
          env = {"RAG_SERVER_URL" => rag_url, "DOT_OPENAI_KEY" => "test"}
          data = JSON.parse(run_cli(env, config, "json"))
          assert_equal [PREVIEW], data.first.fetch('matched_chunks')
          assert_equal %w[path file score matched_chunks], data.first.keys
          assert_equal data, [JSON.parse(run_cli(env, config, "jsonl"))]
          output = run_cli(env, config, "text")
          assert_equal true, output.include?("[notes] #{data.first['file']} score=")
          assert_equal true, output.include?("   #{PREVIEW}\n")
          assert_equal false, output.include?('# score=')
          full = JSON.parse(run_cli(env, config, "json", "--full"))
          assert_equal TEXT, full.fetch('data').first.fetch('anchor_chunk').fetch('text')
          assert_equal full.fetch('data').first, JSON.parse(run_cli(env, config, "jsonl", "--full"))
          full_text = run_cli(env, config, "text", "--full")
          assert_equal true, full_text.include?("#{file}#0 score=")
          assert_equal true, full_text.include?("#{TEXT}\n\n")
        end
      ensure
        fallback&.shutdown
        fallback_thread&.join
        server.shutdown
        thread.join
      end
    end
  end

  private

  def run_cli(env, config, format, *options)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, EXECUTABLE,
      "--config", config, "--format", format, "--brief-chars", "90", *options,
      "backups retained", chdir: ROOT)
    raise "CLI failed: #{status.exitstatus}\n#{stdout}\n#{stderr}" unless status.success?
    assert_equal "", stderr
    stdout
  end

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end
end

if $PROGRAM_NAME == __FILE__
  RunQueryCliTest.new.test_server_and_local_cli_formats_preserve_context_and_full_output
  puts "run_query_cli_test: passed"
end
