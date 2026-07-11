require_relative "http"

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

  response = LlmHttp.post_json!(api_url, data, error_prefix: "Chat error", headers: { "x-goog-api-key" => ENV["DOT_GEMINI_KEY"] })

  result = JSON.parse(response.body)
  result["candidates"][0]["content"]["parts"][0]["text"]
end

# Call Google Gemini embedding API

def gemini_embedding(txts, model, base_url, opts = {})
  api_url = base_url.end_with?('/') ? "#{base_url}#{model}:embedContent" : "#{base_url}/#{model}:embedContent"

  content = { "parts" => [{ "text" => txts }] }
  data = { "model" => "models/#{model}", "content" => content }.merge(opts)

  response = LlmHttp.post_json!(api_url, data, error_prefix: "Embedding error", headers: { "x-goog-api-key" => ENV["DOT_GEMINI_KEY"] })

  result = JSON.parse(response.body)
  result["embedding"]["values"]
end
