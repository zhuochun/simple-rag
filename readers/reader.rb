def get_reader(name)
    case name.downcase
    when "text"
        require_relative "text"
        return TextReader
    else
        return nil
    end
end