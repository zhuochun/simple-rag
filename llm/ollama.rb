require_relative "http"

def embedding_ollama(txts, opts = {})
  data = {
    "model" => "nomic-embed-text",
    "prompt" => txts
  }.merge(opts)

  uri = "http://localhost:11434/api/embeddings"
  response = http_post(uri, nil, data)

  if response.code != "200"
    STDOUT << "Embedding error: #{response}\n"
    exit 1
  end

  result = JSON.parse(response.body)
  result["embedding"]
end