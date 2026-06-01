require_relative "utils/chunk_utils"

def get_reader(name)
    case name.to_s.downcase
    when "text", "notion"
        require_relative "text"
        TextReader
    when "markdown", "md"
        require_relative "markdown"
        MarkdownReader
    when "journal"
        require_relative "journal"
        JournalReader
    else
        nil
    end
end
