require "net/http"
require "json"

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