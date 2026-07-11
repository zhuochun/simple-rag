require_relative "http"

def openai_chat(messages, model, url, opts = {})
  data = {
    "model" => model,
    "messages" => messages
  }.merge(opts)

  response = LlmHttp.post_json!(url, data, error_prefix: "Chat error", headers: { "Authorization" => "Bearer #{ENV['DOT_OPENAI_KEY']}" })

  result = JSON.parse(response.body)
  STDOUT << "Chat usage: #{result["usage"]}, model: #{data["model"]}\n"

  result["choices"][0]["message"]["content"]
end

def openai_embedding(txts, model, url, opts = {})
  data = {
    "model" => model,
    "input" => txts
  }.merge(opts)

  response = LlmHttp.post_json!(url, data, error_prefix: "Embedding error", headers: { "Authorization" => "Bearer #{ENV['DOT_OPENAI_KEY']}" })

  result = JSON.parse(response.body)
  result["data"][0]["embedding"]
end
