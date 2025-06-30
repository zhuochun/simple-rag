require 'net/http'
require_relative '../llm/llm'

JINA_READER_API = 'https://r.jina.ai/'

EXTRACT_PROMPT = <<~PROMPT
Extract the core concepts, opinions and discussions from the following text.
Return the result in concise markdown bullet points.
PROMPT

ARGUE_PROMPT = <<~PROMPT
Given an article and some existing notes, highlight information that is new,
opposing or strongly reinforcing compared to the notes. Respond in concise
markdown bullet points.
PROMPT

# Fetch article markdown using Jina Reader
# url: string
# Returns markdown text

def fetch_article(url)
  uri = URI("#{JINA_READER_API}#{url}")
  request = Net::HTTP::Get.new(uri)
  token = cfg(:jina, 'token', '')
  request['Authorization'] = "Bearer #{token}" unless token.to_s.empty?

  Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    response = http.request(request)
    response.body
  end
end

# Extract core concepts from article markdown
# text: markdown text
# Returns concise markdown bullet points

def extract_article(text)
  msgs = [
    { role: ROLE_SYSTEM, content: EXTRACT_PROMPT },
    { role: ROLE_USER, content: text }
  ]
  chat(msgs)
end

# Compare article with existing notes to highlight new or opposing info
# notes: array of markdown strings
# article: extracted article concepts
# Returns markdown bullet points summarizing differences

def argue_new_content(notes, article)
  msgs = [{ role: ROLE_SYSTEM, content: ARGUE_PROMPT }]
  body = "Notes:\n"
  notes.each { |n| body << "<note>\n#{n}\n</note>\n" }
  body << "\nArticle:\n#{article}"
  msgs << { role: ROLE_USER, content: body }
  chat(msgs)
end
