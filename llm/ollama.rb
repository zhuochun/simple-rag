require_relative "http"

def ollama_embedding(txts, model, url, opts = {})
  data = {
    "model" => model,
    "prompt" => txts
  }.merge(opts)

  response = http_post(url, nil, data)

  if response.code != "200"
    STDOUT << "Embedding error: #{http_error_details(response, url)}\n"
    exit 1
  end

  result = JSON.parse(response.body)
  result["embedding"]
end

def ollama_chat(messages, model, url, opts = {})
  data = {
    "model" => model,
    "messages" => messages
  }.merge(opts)

  response = http_post(url, nil, data)

  if response.code != "200"
    STDOUT << "Chat error: #{http_error_details(response, url)}\n"
    exit 1
  end

  result = JSON.parse(response.body)
  if result.is_a?(Hash) && result["message"]
    result["message"]["content"]
  else
    result["choices"][0]["message"]["content"]
  end
end
