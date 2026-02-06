DISCUSS_PROMPT = <<~PROMPT
You provide a short discussion of a note from multiple perspectives.
Focus on explaining key concepts succinctly.
PROMPT

require_relative "../llm/llm"

# note: string
# query: optional string
# Returns discussion text
def discuss_note(note, query = nil)
    return "" if note.nil? || note.strip.empty?

    user_content = +"Note:\n#{note}"
    if query && !query.strip.empty?
        user_content << "\n\nSearch Query:\n#{query.strip}"
        user_content << "\n\nAlso explain how this note relates to the search query, including direct matches, indirect links, and possible gaps."
    end

    msgs = [
        { role: ROLE_SYSTEM, content: DISCUSS_PROMPT },
        { role: ROLE_USER, content: user_content },
    ]

    chat(msgs)
end
