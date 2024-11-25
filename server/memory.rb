require_relative "../llm/openai"

MEM_PROMPT = """You are an expert at organizing knowledge.
You are given a list of existing knowledges and a new knowledge. Your task is to evaluate and decide: merge the new knowledge with an existing knowledge, or add the new knowledge to the list to reflect the most accurate and atomic capture of knowledge.

Guidelines:
- Eliminate duplicated knowledge and merge related knowledge to ensure a concise list.
- Maintain a consistent and clear style throughout all knowledge, ensuring each entry is concise yet informative.
- If the new knowledge is a variation or extension of an existing knowledge, update the existing knowledge to reflect the new information.
- You are also provided with the matching score (0 to 1) for each existing knowledge to the new knowledge. Make sure to leverage this information to make informed decisions.

Output in markdown:

Operation: Merge or Add
Reasoning: Explain your decision
Updated knowledge: Provide the knowledge item if you decided to merge
"""

def update_memory(q, existing)
    msgs = [{ role: ROLE_SYSTEM, content: MEM_PROMPT }]

    return "" if existing[0][:text].include?(q)

    kw = "Existing knowledge:\n"
    existing.take(3).each do |item|
        kw << "<knowledge>\n#{item[:text]}\n</knowledge>\n"
    end
    kw << "New knowledge:\n<knowledge>\n#{q}\n</knowledge>"

    msgs << { role: ROLE_USER, content: kw }

    return chat(msgs)
end