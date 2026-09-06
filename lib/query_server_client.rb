require "json"
require "digest"
require "net/http"
require "socket"
require "uri"

module QueryServerClient
  DEFAULT_URL = "http://127.0.0.1:4567".freeze
  HEALTH_OPEN_TIMEOUT = 0.2
  HEALTH_READ_TIMEOUT = 0.5
  QUERY_OPEN_TIMEOUT = 1
  QUERY_READ_TIMEOUT = 600

  class QueryError < StandardError
  end

  module_function

  def retrieve(config_file:, query:, path_names:, top_n:, base_url: ENV["RAG_SERVER_URL"])
    base_url = DEFAULT_URL if base_url.to_s.strip.empty?
    health = retrieve_health(base_url)
    return nil unless health
    return nil unless matching_config?(health, config_file)

    response = begin
      post_json(
        endpoint(base_url, "/q"),
        {
          q: query,
          paths: path_names,
          topN: top_n,
        },
        open_timeout: QUERY_OPEN_TIMEOUT,
        read_timeout: QUERY_READ_TIMEOUT
      )
    rescue QueryError
      raise
    rescue => e
      raise QueryError, "Query server request failed: #{concise_error(e)}"
    end
    symbolize(response)
  end

  def retrieve_health(base_url)
    health = get_json(
      endpoint(base_url, "/health"),
      open_timeout: HEALTH_OPEN_TIMEOUT,
      read_timeout: HEALTH_READ_TIMEOUT
    )
    health if health.is_a?(Hash)
  rescue QueryError, SystemCallError, IOError, SocketError,
         Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Net::HTTPBadResponse, URI::InvalidURIError
    nil
  end

  def get_json(uri, open_timeout:, read_timeout:)
    if uri.scheme == "http" && %w[127.0.0.1 localhost ::1].include?(uri.hostname)
      return local_get_json(uri, open_timeout: open_timeout, read_timeout: read_timeout)
    end
    request_json(Net::HTTP::Get.new(uri), uri, open_timeout: open_timeout, read_timeout: read_timeout)
  end

  def local_get_json(uri, open_timeout:, read_timeout:)
    # Net::HTTP's blocking TCPSocket.open cannot be interrupted promptly on
    # Windows Ruby. Use a nonblocking connect deadline for the local probe,
    # then retain the standard HTTP parser (including chunked responses).
    Socket.tcp(uri.hostname, uri.port, connect_timeout: open_timeout, resolv_timeout: open_timeout) do |socket|
      io = Net::BufferedIO.new(socket, read_timeout: read_timeout, write_timeout: read_timeout)
      request = Net::HTTP::Get.new(uri, "Connection" => "close", "Accept-Encoding" => "identity")
      request.exec(io, "1.1", uri.request_uri)
      begin
        response = Net::HTTPResponse.read_new(io)
      end while response.is_a?(Net::HTTPInformation)
      response.reading_body(io, true) { response.body }
      parse_response(response)
    end
  end

  def post_json(uri, payload, open_timeout:, read_timeout:)
    request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    request.body = JSON.generate(payload)
    request_json(request, uri, open_timeout: open_timeout, read_timeout: read_timeout)
  end

  def request_json(request, uri, open_timeout:, read_timeout:)
    response = Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: open_timeout,
      read_timeout: read_timeout
    ) { |http| http.request(request) }
    parse_response(response)
  end

  def parse_response(response)
    body = response.body.to_s
    parsed = JSON.parse(body)
    return parsed if response.is_a?(Net::HTTPSuccess)

    message = parsed.is_a?(Hash) ? parsed["error"] : nil
    raise QueryError, message.to_s.empty? ? "Query server returned HTTP #{response.code}" : message
  rescue JSON::ParserError
    if response&.is_a?(Net::HTTPSuccess)
      raise QueryError, "Query server returned invalid JSON"
    end

    detail = response&.body.to_s.strip.gsub(/\s+/, " ")[0, 300]
    suffix = detail.empty? ? "" : ": #{detail}"
    raise QueryError, "Query server returned HTTP #{response&.code}#{suffix}"
  end

  def endpoint(base_url, path)
    uri = URI(base_url)
    uri.path = path
    uri.query = nil
    uri.fragment = nil
    uri
  end

  def same_config?(server_config, local_config)
    normalized_path(server_config) == normalized_path(local_config)
  end

  def matching_config?(health, local_config)
    return false unless same_config?(health["config"], local_config)

    server_digest = health["configDigest"].to_s
    return false if server_digest.empty?

    Digest::SHA256.file(local_config).hexdigest == server_digest
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def normalized_path(path)
    expanded = File.expand_path(path.to_s).tr("\\", "/")
    Gem.win_platform? ? expanded.downcase : expanded
  end

  def symbolize(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, item), out| out[key.to_sym] = symbolize(item) }
    when Array
      value.map { |item| symbolize(item) }
    else
      value
    end
  end

  def concise_error(error)
    message = error.message.to_s.lines.first.to_s.strip
    message.empty? ? error.class.to_s : "#{error.class}: #{message}"
  end
end
