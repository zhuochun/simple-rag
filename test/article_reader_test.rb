require "tmpdir"

require_relative "../server/article"
require_relative "test_assertions"

class ArticleReaderTest
  include TestAssertions

  Response = Struct.new(:code, :message, :body) do
    def to_hash
      {}
    end
  end

  class FakeHttp
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout

    def initialize(response)
      @response = response
    end

    def request(_request)
      @response
    end
  end

  def test_fetch_validates_source_url_and_rejects_upstream_errors
    bad_http = FakeHttp.new(Response.new("503", "Unavailable", "later"))
    reader = SimpleRag::ArticleReader.new(http_factory: ->(_uri) { bad_http })

    assert_raises(ArgumentError) { reader.fetch_and_cache("file:///secret") }
    error = assert_raises(RuntimeError) { reader.fetch_and_cache("https://example.test/article") }
    assert_equal true, error.message.include?("503")
  end

  def test_fetch_and_cache_returns_successful_content
    Dir.mktmpdir("article-reader-", __dir__) do |dir|
      http = FakeHttp.new(Response.new("200", "OK", "# Article"))
      reader = SimpleRag::ArticleReader.new(cache_dir: dir, http_factory: ->(_uri) { http })

      result = reader.fetch_and_cache("https://example.test/article")

      assert_equal "# Article", result[:article]
      assert_equal true, File.file?(result[:cached_file])
    end
  end

  private

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

end

if $PROGRAM_NAME == __FILE__
  test = ArticleReaderTest.new
  test.test_fetch_validates_source_url_and_rejects_upstream_errors
  puts "test_fetch_validates_source_url_and_rejects_upstream_errors: passed"
  test.test_fetch_and_cache_returns_successful_content
  puts "test_fetch_and_cache_returns_successful_content: passed"
end
