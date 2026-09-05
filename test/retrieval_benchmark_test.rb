require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "webrick"

require_relative "../storage/sqlite_index"

class RetrievalBenchmarkTest
  EXECUTABLE = File.expand_path("benchmark/retrieval_benchmark.rb", __dir__)

  def test_benchmark_reports_standard_expanded_and_fallback_timings
    server = WEBrick::HTTPServer.new(
      BindAddress: "127.0.0.1", Port: 0,
      Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL), AccessLog: []
    )
    fail_variants = false
    server.mount_proc "/api/tags" do |_request, response|
      response.body = JSON.generate(models: [])
    end
    server.mount_proc "/api/embeddings" do |_request, response|
      response.body = JSON.generate(embedding: [1.0, 0.0])
    end
    server.mount_proc "/api/chat" do |request, response|
      prompt = JSON.parse(request.body).fetch("messages").first.fetch("content")
      rewrite = prompt.start_with?("Rewrite")
      if fail_variants && !rewrite
        response.status = 503
        response.body = JSON.generate(error: "unavailable")
      else
        message = { content: rewrite ? "rewritten alpha" : "alias" }
        response.body = JSON.generate(message: message, choices: [{ message: message }])
      end
    end
    worker = Thread.new { server.start }

    Dir.mktmpdir("retrieval-benchmark-") do |dir|
      store = SqliteIndex.new(File.join(dir, "index.sqlite"), "chunks")
      store.transaction do
        store.upsert_chunks([{ path: "alpha.md", chunk: 0, hash: "alpha",
                               embedding: [1.0, 0.0], text: "alpha alias", bucket: 0 }])
      end
      store.close
      base = "http://127.0.0.1:#{server.config[:Port]}"
      config_file = File.join(dir, "config.json")
      queries_file = File.join(dir, "queries.txt")
      File.write(queries_file, "alpha\n")
      config = {
        embedding: { provider: "ollama", model: "test", url: "#{base}/api/embeddings" },
        chat: { provider: "ollama", model: "test", url: "#{base}/api/chat" },
        paths: [{ name: "docs", db: "#{File.join(dir, 'index.sqlite')}@chunks", dir: dir, searchDefault: true, threshold: 0.0 }]
      }

      scenarios = [["q", false, "ollama"], ["q_plus", false, "ollama"],
                   ["q_plus", true, "ollama"], ["q_plus", false, "openai"],
                   ["q_plus", false, "openrouter"]]
      scenarios.each do |mode, fallback, provider|
        fail_variants = fallback
        config[:chat][:provider] = provider
        File.write(config_file, JSON.generate(config))
        stdout, stderr, status = Open3.capture3(
          { "DOT_OPENAI_KEY" => "test", "DOT_OPENROUTER_KEY" => "test" },
          RbConfig.ruby, EXECUTABLE, "--config", config_file, "--queries", queries_file,
          "--mode", mode, "--warmup", "1", "--runs", "1", "--json"
        )
        raise "Benchmark failed: #{stdout}\n#{stderr}" unless status.success?
        assert_equal true, stderr.include?("Chat usage:") unless provider == "ollama"
        summary = JSON.parse(stdout)
        assert_equal mode, summary.fetch("requested_mode")
        assert_equal(fallback ? 1 : 0, summary.fetch("fallback_count"))
        assert_equal 1, summary.fetch("sample_count")
        assert_equal 1, summary.fetch("warmup_samples").length
        sample = summary.fetch("samples").first
        assert_equal(fallback ? "q" : mode, sample.fetch("effective_mode"))
        assert_equal 1, sample.fetch("result_count")
        phases = %w[planning_ms embedding_ms local_retrieval_ms].map { |key| sample.fetch(key) }
        raise "Negative phase timing: #{phases}" unless phases.all? { |value| value >= 0 }
        raise "Phase timings do not sum to total" unless (phases.sum - sample.fetch("total_ms")).abs <= 0.2
      end
    end
  ensure
    server&.shutdown
    worker&.join
  end

  private

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end
end

if $PROGRAM_NAME == __FILE__
  RetrievalBenchmarkTest.new.test_benchmark_reports_standard_expanded_and_fallback_timings
  puts "test_benchmark_reports_standard_expanded_and_fallback_timings: passed"
end
