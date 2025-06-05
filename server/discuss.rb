DISCUSS_PROMPT = <<~PROMPT
You provide a short discussion of a note from multiple perspectives.
Focus on explaining key concepts succinctly.
PROMPT

require_relative "../llm/openai"

# note: string
# Returns discussion text
def discuss_note(note)
    return "" if note.nil? || note.strip.empty?

    msgs = [
        { role: ROLE_SYSTEM, content: DISCUSS_PROMPT },
        { role: ROLE_USER, content: note },
    ]

    chat(msgs)
end
