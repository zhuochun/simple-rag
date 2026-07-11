require "json"
require "net/http"
require "uri"

module LlmHttp
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 600
  WRITE_TIMEOUT = 60

  module_function

  def post_json(uri, payload, headers: {}, http_factory: nil, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, write_timeout: WRITE_TIMEOUT)
    url = parse_uri(uri)
    http = (http_factory || method(:build_http)).call(url)
    configure(http, url, open_timeout: open_timeout, read_timeout: read_timeout, write_timeout: write_timeout)
    request = Net::HTTP::Post.new(url, { "Content-Type" => "application/json" }.merge(headers))
    request.body = JSON.generate(payload)
    http.request(request)
  end

  def post_json!(uri, payload, error_prefix:, headers: {}, **options)
    response = post_json(uri, payload, headers: headers, **options)
    raise_error(error_prefix, response, uri) unless success?(response)
    response
  end

  def get(uri, headers: {}, http_factory: nil, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, write_timeout: WRITE_TIMEOUT)
    url = parse_uri(uri)
    http = (http_factory || method(:build_http)).call(url)
    configure(http, url, open_timeout: open_timeout, read_timeout: read_timeout, write_timeout: write_timeout)
    http.request(Net::HTTP::Get.new(url, headers))
  end

  def get!(uri, error_prefix:, headers: {}, **options)
    response = get(uri, headers: headers, **options)
    raise_error(error_prefix, response, uri) unless success?(response)
    response
  end

  def success?(response)
    response.code.to_i.between?(200, 299)
  end

  def raise_error(prefix, response, url = nil)
    raise RuntimeError, "#{prefix}: #{error_details(response, url)}"
  end

  def error_details(response, url = nil)
    body = response.respond_to?(:body) ? response.body.to_s : ""
    parsed = parse_error_body(body)
    headers = response.respond_to?(:to_hash) ? response.to_hash : {}
    request_id = (headers["x-request-id"] || headers["x-request_id"] || headers["x-openai-request-id"] || headers["x-google-request-id"])&.first
    parts = ["code=#{response.code}", "message=#{response.message}"]
    parts << "request_id=#{request_id}" if request_id
    parts << "url=#{url}" if url
    parts << "body=#{parsed}" unless parsed.empty?
    parts.join(", ")
  end

  def build_http(uri)
    Net::HTTP.new(uri.host, uri.port)
  end

  def configure(http, uri, open_timeout:, read_timeout:, write_timeout:)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = open_timeout
    http.read_timeout = read_timeout
    http.write_timeout = write_timeout if http.respond_to?(:write_timeout=)
  end

  def parse_uri(raw)
    uri = URI(raw.to_s)
    unless %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?
      raise ArgumentError, "HTTP URL must use http or https and include a host"
    end

    uri
  rescue URI::InvalidURIError => error
    raise ArgumentError, "Invalid HTTP URL: #{error.message}"
  end

  def parse_error_body(body)
    trimmed = body.strip
    return "" if trimmed.empty?

    parsed = JSON.parse(trimmed)
    parsed.is_a?(Hash) && parsed.key?("error") ? JSON.generate(parsed["error"]) : JSON.generate(parsed)
  rescue JSON::ParserError
    trimmed[0, 1_000]
  end
  private_class_method :post_json, :get, :success?, :raise_error, :error_details,
                       :build_http, :configure, :parse_uri, :parse_error_body
end
