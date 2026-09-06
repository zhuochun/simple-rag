require_relative "../lib/query_server_client"
require_relative "test_assertions"

module QueryServerClientTest
  extend TestAssertions
  module_function

  def run
    test_same_config
    test_matching_config
    test_symbolize
    test_health_failure_falls_back
    test_unavailable_loopback_health_is_bounded
    test_loopback_health_response
    test_loopback_health_read_failure_falls_back
    test_query_transport_failure_is_not_retried_locally
    puts "query_server_client_test: passed"
  end

  def test_same_config
    path = File.expand_path("../config.json", __dir__)
    assert QueryServerClient.same_config?(path, path)
    refute QueryServerClient.same_config?(path, "#{path}.other")
  end

  def test_matching_config
    path = File.expand_path(__FILE__)
    health = {
      "config" => path,
      "configDigest" => Digest::SHA256.file(path).hexdigest,
    }
    assert QueryServerClient.matching_config?(health, path)
    health["configDigest"] = "stale"
    refute QueryServerClient.matching_config?(health, path)
  end

  def test_symbolize
    value = QueryServerClient.symbolize(
      "data" => [{ "path" => "docs", "anchor_chunk" => { "chunk" => 1 } }]
    )
    assert_equal "docs", value[:data][0][:path]
    assert_equal 1, value[:data][0][:anchor_chunk][:chunk]
  end

  def test_health_failure_falls_back
    with_stubbed_method(:get_json, ->(*) { raise Net::OpenTimeout }) do
      result = QueryServerClient.retrieve(
        config_file: "config.json",
        query: "alpha",
        path_names: ["docs"],
        top_n: 10
      )
      assert_equal nil, result
    end
  end

  def test_query_transport_failure_is_not_retried_locally
    calls = 0
    get_json = lambda do |*|
      calls += 1
      config = File.expand_path(__FILE__)
      {
        "config" => config,
        "configDigest" => Digest::SHA256.file(config).hexdigest,
      }
    end
    post_json = ->(*) { raise Net::ReadTimeout }

    with_stubbed_method(:get_json, get_json) do
      with_stubbed_method(:post_json, post_json) do
        error = assert_raises(QueryServerClient::QueryError) do
          QueryServerClient.retrieve(
            config_file: File.expand_path(__FILE__),
            query: "alpha",
            path_names: ["docs"],
            top_n: 10
          )
        end
        assert error.message.include?("Query server request failed")
        assert_equal 1, calls
      end
    end
  end

  def test_unavailable_loopback_health_is_bounded
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.addr[1]
    listener.close
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal nil, QueryServerClient.retrieve_health("http://127.0.0.1:#{port}")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    raise "Unavailable health check took #{elapsed.round(3)}s (budget 0.8s)" unless elapsed < 0.8
  ensure
    listener&.close unless listener&.closed?
  end

  def test_loopback_health_response
    body = JSON.generate("config" => __FILE__, "configDigest" => "digest")
    response = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    with_health_server(->(client) { client.write(response) }) do |url|
      assert_equal JSON.parse(body), QueryServerClient.retrieve_health(url)
    end
    chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n#{body.bytesize.to_s(16)}\r\n#{body}\r\n0\r\n\r\n"
    with_health_server(->(client) { client.write(chunked) }) do |url|
      assert_equal JSON.parse(body), QueryServerClient.retrieve_health(url)
    end
  end

  def test_loopback_health_read_failure_falls_back
    with_health_server(->(_client) { sleep 1 }) do |url|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal nil, QueryServerClient.retrieve_health(url)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      raise "Stalled health response took #{elapsed.round(3)}s" unless elapsed < 0.9
    end
    [
      "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nnope",
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]",
      "HTTP/1.1 503 Unavailable\r\nContent-Length: 2\r\n\r\n{}",
      "invalid response\r\n\r\n",
      "",
    ].each do |response|
      with_health_server(->(client) { client.write(response) }) do |url|
        assert_equal nil, QueryServerClient.retrieve_health(url)
      end
    end
  end

  def with_health_server(handler)
    listener = TCPServer.new("127.0.0.1", 0)
    worker = Thread.new do
      client = listener.accept
      request = []
      while (line = client.gets)
        request << line
        break if line == "\r\n"
      end
      assert_equal "GET /health HTTP/1.1\r\n", request.first
      handler.call(client)
    ensure
      client&.close
    end
    yield "http://127.0.0.1:#{listener.addr[1]}"
    worker.value
  ensure
    listener&.close
    worker&.kill if worker&.alive?
    worker&.join
  end

  def with_stubbed_method(name, implementation)
    singleton = QueryServerClient.singleton_class
    original = QueryServerClient.method(name)
    singleton.send(:define_method, name, implementation)
    yield
  ensure
    singleton.send(:define_method, name, original)
  end

  def assert(value)
    raise "Expected truthy value" unless value
  end

  def refute(value)
    raise "Expected falsey value" if value
  end

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

end

QueryServerClientTest.run if $PROGRAM_NAME == __FILE__
