require_relative "http"

# Chat with OpenRouter

def openrouter_chat(messages, model, url, opts = {})
  data = {
    "model" => model,
    "messages" => messages
  }.merge(opts)

  response = http_post(url, OPENROUTER_KEY, data)

  if response.code != "200"
    raise_http_error("Chat error", response, url)
  end

  result = JSON.parse(response.body)
  STDOUT << "Chat usage: #{result["usage"]}, model: #{data["model"]}\n"

  result["choices"][0]["message"]["content"]
end

# Create embeddings with OpenRouter

def openrouter_embedding(txts, model, url, opts = {})
  data = {
    "model" => model,
    "input" => txts
  }.merge(opts)

  response = http_post(url, OPENROUTER_KEY, data)

  if response.code != "200"
    raise_http_error("Embedding error", response, url)
  end

  result = JSON.parse(response.body)
  result["data"][0]["embedding"]
end
