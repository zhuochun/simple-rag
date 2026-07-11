require "json"

require_relative "../llm/http"

class HttpTest
  FakeResponse = Struct.new(:code, :message, :body) do
    def to_hash
      {}
    end
  end

  class FakeHttp
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout
    attr_reader :last_request

    def request(request)
      @last_request = request
      FakeResponse.new("200", "OK", "{}")
    end
  end

  def test_post_json_applies_all_timeouts_and_headers
    http = FakeHttp.new

    response = LlmHttp.post_json!(
      "https://example.test/messages",
      { prompt: "hello" },
      error_prefix: "request failed",
      headers: { "Authorization" => "Bearer token" },
      http_factory: ->(_uri) { http }
    )

    assert_equal "200", response.code
    assert_equal true, http.use_ssl
    assert_equal LlmHttp::OPEN_TIMEOUT, http.open_timeout
    assert_equal LlmHttp::READ_TIMEOUT, http.read_timeout
    assert_equal LlmHttp::WRITE_TIMEOUT, http.write_timeout
    assert_equal "Bearer token", http.last_request["Authorization"]
    assert_equal({ "prompt" => "hello" }, JSON.parse(http.last_request.body))
  end

  private

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end
end

if $PROGRAM_NAME == __FILE__
  test = HttpTest.new
  test.test_post_json_applies_all_timeouts_and_headers
  puts "test_post_json_applies_all_timeouts_and_headers: passed"
end
