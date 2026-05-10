require "uri"

require_relative "http"

def ollama_url(url)
  uri = URI(url)
  uri.host = "127.0.0.1" if uri.host.to_s.downcase == "localhost"
  uri.to_s
rescue URI::InvalidURIError
  url
end

def ollama_embedding(txts, model, url, opts = {})
  url = ollama_url(url)
  data = {
    "model" => model,
    "prompt" => txts
  }.merge(opts)

  response = http_post(url, nil, data)

  if response.code != "200"
    raise_http_error("Embedding error", response, url)
  end

  result = JSON.parse(response.body)
  result["embedding"]
end

def ollama_chat(messages, model, url, opts = {})
  url = ollama_url(url)
  data = {
    "model" => model,
    "messages" => messages,
    "stream" => false,
    "think" => false
  }.merge(opts)

  # Always request a single final response payload from Ollama.
  data["stream"] = false
  # Disable thinking/reasoning traces in models that support the toggle.
  data["think"] = false

  response = http_post(url, nil, data)

  if response.code != "200"
    raise_http_error("Chat error", response, url)
  end

  result = JSON.parse(response.body)
  if result.is_a?(Hash) && result["message"]
    result["message"]["content"]
  else
    result["choices"][0]["message"]["content"]
  end
end
