require_relative "../lib/query_server_client"

module QueryServerClientTest
  module_function

  def run
    test_same_config
    test_matching_config
    test_symbolize
    test_health_failure_falls_back
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

  def assert_raises(error_class)
    yield
    raise "Expected #{error_class}, but nothing was raised"
  rescue error_class => e
    e
  end
end

QueryServerClientTest.run if $PROGRAM_NAME == __FILE__
