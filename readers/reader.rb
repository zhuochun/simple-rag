READERS = %w[text note journal]

def get_reader(name)
    case name.to_s.downcase
    when "text"
        require_relative "text"
        TextReader
    when "note"
        require_relative "note"
        NoteReader
    when "journal"
        require_relative "journal"
        JournalReader
    else
        nil
    end
end

def available_readers
    READERS
end
