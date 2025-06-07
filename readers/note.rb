
class NoteReader
    HEADER_CONF = /^## (.+?) \[(.+?)\]$/
    LINK = /^- \[([ xX])\] /

    Note = Struct.new(:lineno, :body, :title, :done)

    attr_accessor :file, :chunks, :notes

    def initialize(file)
        @file = file
        @loaded = false
        @chunks = []
        @notes = []
    end

    def load
        return if @loaded

        File.open(@file) do |file|
            parse_conf(file)
        end

        @notes.each do |note|
            next unless note.done
            chunks << note.body.join("\n")
        end

        @loaded = true
        self
    end

    # ## Title [Author - Conf]
    #
    # - [x] http://link
    #
    # **Summary:**
    def parse_conf(file)
        note = nil

        file.each_line do |line|
            line = line.chomp # remove crlf chars

            if line =~ HEADER_CONF
                # close the previous note
                if !note.nil?
                    @notes << note
                    note = nil
                end

                note = Note.new
                note.lineno = file.lineno
                note.title = $1
                note.body = [line]
            elsif !note.nil?
                if line =~ LINK # skip links in body
                    note.done = ($1 != ' ')
                else
                    note.body << line unless line.strip.empty?
                end
            end
        end

        # append the last parsed note if the file does not end with another header
        if !note.nil?
            @notes << note
            note = nil
        end
    end

    def get_chunk(idx)
        @chunks[idx || 0]
    end
end
