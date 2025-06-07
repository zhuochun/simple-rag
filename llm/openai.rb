require_relative "http"

def openai_chat(messages, model, url, opts = {})
  data = {
    "model" => model,
    "messages" => messages
  }.merge(opts)

  response = http_post(url, OPENAI_KEY, data)

  if response.code != "200"
    STDOUT << "Chat error: #{response}\n"
    exit 1
  end

  result = JSON.parse(response.body)
  STDOUT << "Chat usage: #{result["usage"]}, model: #{data["model"]}\n"

  result["choices"][0]["message"]["content"]
end

def openai_embedding(txts, model, url, opts = {})
  data = {
    "model" => model,
    "input" => txts
  }.merge(opts)

  response = http_post(url, OPENAI_KEY, data)

  if response.code != "200"
    STDOUT << "Embedding error: #{response.body}\n"
    exit 1
  end

  result = JSON.parse(response.body)
  result["data"][0]["embedding"]
end
