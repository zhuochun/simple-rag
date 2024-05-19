def get_reader(name)
    case name.downcase
    when "text"
        require_relative "text"
        return TextReader
    when "note"
        require_relative "note"
        return NoteReader
    else
        return nil
    end
end