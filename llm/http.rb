require "net/http"
require "json"

def http_error_details(response, url = nil)
  code = response.respond_to?(:code) ? response.code : nil
  message = response.respond_to?(:message) ? response.message : nil
  body = response.respond_to?(:body) ? response.body.to_s : ""

  parsed = nil
  begin
    trimmed = body.strip
    parsed = JSON.parse(trimmed) if !trimmed.empty? && (trimmed.start_with?("{") || trimmed.start_with?("["))
  rescue
    parsed = nil
  end

  error_msg = if parsed.is_a?(Hash)
                parsed["error"] ? parsed["error"].to_json : parsed.to_json
              else
                body
              end

  headers = response.respond_to?(:to_hash) ? response.to_hash : {}
  req_id = (headers["x-request-id"] || headers["x-request_id"] || headers["x-openai-request-id"] || headers["x-google-request-id"])&.first

  parts = []
  parts << "code=#{code}" if code
  parts << "message=#{message}" if message
  parts << "request_id=#{req_id}" if req_id
  parts << "url=#{url}" if url
  parts << "body=#{error_msg}" if error_msg && !error_msg.empty?

  parts.join(", ")
end

def raise_http_error(prefix, response, url = nil)
  details = http_error_details(response, url)
  raise RuntimeError, "#{prefix}: #{details}"
end

def http_post(uri, auth, reqData)
  url = URI(uri)

  http = Net::HTTP.new(url.host, url.port)
  http.use_ssl = true unless auth.nil?
  http.read_timeout = 600 # Time in seconds

  headers = { "Content-Type" => "application/json" }
  headers["Authorization"] = "Bearer #{auth}" unless auth.nil?

  request = Net::HTTP::Post.new(url, headers)
  request.body = reqData.to_json

  return http.request(request)
end
