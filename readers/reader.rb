READERS = %w[text note]

def get_reader(name)
    case name.to_s.downcase
    when "text"
        require_relative "text"
        TextReader
    when "note"
        require_relative "note"
        NoteReader
    else
        nil
    end
end

def available_readers
    READERS
end
