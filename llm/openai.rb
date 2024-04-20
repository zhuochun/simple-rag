require_relative "http"

ROLE_SYSTEM = "system"
ROLE_USER = "user"
ROLE_ASSISTANT = "assistant"
NEXT_ROLE = ->(role) { role != ROLE_USER ? ROLE_USER : ROLE_ASSISTANT }

def chat(messages, opts = {})
  data = {
    "model" => "gpt-3.5-turbo-16k",
    "messages" => messages
  }.merge(opts)

  uri = "https://api.openai.com/v1/chat/completions"
  response = http_post(uri, OPENAI_KEY, data)

  if response.code != "200"
    STDOUT << "Chat error: #{response}\n"
    exit 1
  end

  result = JSON.parse(response.body)
  STDOUT << "Chat usage: #{result["usage"]}, model: #{data["model"]}\n"

  result["choices"][0]["message"]["content"]
end

def embedding(txts, opts = {})
  data = {
    "model" => "text-embedding-3-small",
    "input" => txts
  }.merge(opts)

  uri = "https://api.openai.com/v1/embeddings"
  response = http_post(uri, OPENAI_KEY, data)

  if response.code != "200"
    STDOUT << "Embedding error: #{response.body}\n"
    exit 1
  end

  result = JSON.parse(response.body)
  result["data"][0]["embedding"]
end