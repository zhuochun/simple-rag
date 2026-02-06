require_relative "http"

def ollama_embedding(txts, model, url, opts = {})
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
  data = {
    "model" => model,
    "messages" => messages,
    "stream" => false
  }.merge(opts)

  # Always request a single final response payload from Ollama.
  data["stream"] = false

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
