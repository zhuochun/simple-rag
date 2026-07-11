require "json"
require "rack/mock"

require_relative "../server/app"

class ServerAppTest
  class FakeRuntime
    attr_reader :dismissed

    def health
      { status: "ok" }
    end

    def dismiss(data)
      @dismissed = data.fetch("id")
      { ok: true }
    end
  end

  def test_all_json_routes_reject_malformed_json_consistently
    app = SimpleRag::ServerApp.for_runtime(runtime: FakeRuntime.new)
    client = Rack::MockRequest.new(app)
    routes = %w[
      /map_note
      /q
      /q_plus
      /discuss
      /duplicates
      /dismiss
      /random
      /similar
      /reader/load_cache_article
      /reader/fetch_url
      /reader/extract_notes
    ]

    routes.each do |route|
      response = client.post(route, "CONTENT_TYPE" => "application/json", input: "{")
      assert_equal 400, response.status
      assert_equal "Invalid JSON", JSON.parse(response.body).fetch("error").split(":").first
    end
  end

  def test_health_uses_injected_runtime
    app = SimpleRag::ServerApp.for_runtime(runtime: FakeRuntime.new)
    response = Rack::MockRequest.new(app).get("/health")

    assert_equal 200, response.status
    assert_equal({ "status" => "ok" }, JSON.parse(response.body))
  end

  def test_valid_json_is_delegated_to_the_runtime
    runtime = FakeRuntime.new
    app = SimpleRag::ServerApp.for_runtime(runtime: runtime)
    response = Rack::MockRequest.new(app).post(
      "/dismiss",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(id: "cluster-1")
    )

    assert_equal 200, response.status
    assert_equal "cluster-1", runtime.dismissed
    assert_equal({ "ok" => true }, JSON.parse(response.body))
  end

  private

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end
end

if $PROGRAM_NAME == __FILE__
  test = ServerAppTest.new
  test.test_all_json_routes_reject_malformed_json_consistently
  puts "test_all_json_routes_reject_malformed_json_consistently: passed"
  test.test_health_uses_injected_runtime
  puts "test_health_uses_injected_runtime: passed"
  test.test_valid_json_is_delegated_to_the_runtime
  puts "test_valid_json_is_delegated_to_the_runtime: passed"
end
