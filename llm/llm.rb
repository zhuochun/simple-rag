require_relative "openai"
require_relative "ollama"
require_relative "gemini"
require_relative "openrouter"

ROLE_SYSTEM = "system"
ROLE_USER = "user"
ROLE_ASSISTANT = "assistant"
NEXT_ROLE = ->(role) { role != ROLE_USER ? ROLE_USER : ROLE_ASSISTANT }

# Fetch configuration value with defaults
# Supports Hash or OpenStruct configuration objects

def cfg(section, key, default)
  return default unless defined?(CONFIG)
  sec = CONFIG.send(section) if CONFIG.respond_to?(section)
  return default unless sec

  if sec.is_a?(Hash)
    sec.fetch(key, default)
  elsif sec.respond_to?(key)
    val = sec.send(key)
    val.nil? ? default : val
  else
    default
  end
end

# Route chat requests based on provider configuration

def chat(messages, opts = {})
  provider = cfg(:chat, 'provider', 'openai').downcase
  case provider
  when 'ollama'
    model = cfg(:chat, 'model', 'llama2')
    url = cfg(:chat, 'url', 'http://localhost:11434/api/chat')
    ollama_chat(messages, model, url, opts)
  when 'gemini'
    model = cfg(:chat, 'model', 'gemini-2.5-flash')
    url = cfg(:chat, 'url', 'https://generativelanguage.googleapis.com/v1beta/models')
    gemini_chat(messages, model, url, opts)
  when 'openrouter'
    model = cfg(:chat, 'model', 'gpt-4.1-mini')
    url = cfg(:chat, 'url', 'https://openrouter.ai/api/v1/chat/completions')
    openrouter_chat(messages, model, url, opts)
  else
    model = cfg(:chat, 'model', 'gpt-4.1-mini')
    url = cfg(:chat, 'url', 'https://api.openai.com/v1/chat/completions')
    openai_chat(messages, model, url, opts)
  end
end

# Route embedding requests based on provider configuration

def embedding(txts, opts = {})
  provider = cfg(:embedding, 'provider', 'openai').downcase
  case provider
  when 'ollama'
    model = cfg(:embedding, 'model', 'nomic-embed-text')
    url = cfg(:embedding, 'url', 'http://localhost:11434/api/embeddings')
    ollama_embedding(txts, model, url, opts)
  when 'gemini'
    model = cfg(:embedding, 'model', 'gemini-embedding-001')
    url = cfg(:embedding, 'url', 'https://generativelanguage.googleapis.com/v1beta/models')
    gemini_embedding(txts, model, url, opts)
  when 'openrouter'
    model = cfg(:embedding, 'model', 'text-embedding-3-small')
    url = cfg(:embedding, 'url', 'https://openrouter.ai/api/v1/embeddings')
    openrouter_embedding(txts, model, url, opts)
  else
    model = cfg(:embedding, 'model', 'text-embedding-3-small')
    url = cfg(:embedding, 'url', 'https://api.openai.com/v1/embeddings')
    openai_embedding(txts, model, url, opts)
  end
end
