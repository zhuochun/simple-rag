require_relative "http"

# Send POST request to Gemini API with API key header

def gemini_http_post(uri, key, data)
  url = URI(uri)
  http = Net::HTTP.new(url.host, url.port)
  http.use_ssl = true
  http.read_timeout = 600

  headers = { "Content-Type" => "application/json", "x-goog-api-key" => key }
  request = Net::HTTP::Post.new(url, headers)
  request.body = data.to_json

  http.request(request)
end

# Call Google Gemini chat API

def gemini_chat(messages, model, base_url, opts = {})
  api_url = base_url.end_with?('/') ? "#{base_url}#{model}:generateContent" : "#{base_url}/#{model}:generateContent"

  contents = messages.map do |m|
    {
      "role" => m[:role] || m["role"],
      "parts" => [{ "text" => m[:content] || m["content"] }]
    }
  end
  data = { "contents" => contents }.merge(opts)

  response = gemini_http_post(api_url, GEMINI_KEY, data)

  if response.code != "200"
    STDOUT << "Chat error: #{http_error_details(response, api_url)}\n"
    exit 1
  end

  result = JSON.parse(response.body)
  result["candidates"][0]["content"]["parts"][0]["text"]
end

# Call Google Gemini embedding API

def gemini_embedding(txts, model, base_url, opts = {})
  api_url = base_url.end_with?('/') ? "#{base_url}#{model}:embedContent" : "#{base_url}/#{model}:embedContent"

  content = { "parts" => [{ "text" => txts }] }
  data = { "model" => "models/#{model}", "content" => content }.merge(opts)

  response = gemini_http_post(api_url, GEMINI_KEY, data)

  if response.code != "200"
    STDOUT << "Embedding error: #{http_error_details(response, api_url)}\n"
    exit 1
  end

  result = JSON.parse(response.body)
  result["embedding"]["values"]
end
