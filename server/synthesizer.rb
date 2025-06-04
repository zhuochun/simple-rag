SUM_PROMPT = """You are an expert at combining notes.
Given a collection of notes, synthesize them into a concise new note capturing the key points.
"""

require_relative "../llm/openai"

# notes: array of strings
# Returns summary text
def synthesize_notes(notes)
    return "" if notes.nil? || notes.empty?

    msgs = [{ role: ROLE_SYSTEM, content: SUM_PROMPT }]
    content = "Notes:\n"
    notes.each do |n|
        content << "<note>\n#{n}\n</note>\n"
    end
    msgs << { role: ROLE_USER, content: content }

    chat(msgs)
end
