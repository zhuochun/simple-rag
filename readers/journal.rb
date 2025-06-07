class JournalReader
    SKIP_HEADINGS = ["\u7CBE\u529B", "\u611F\u6069"]

    attr_accessor :file, :chunks

    def initialize(file)
        @file = file
        @loaded = false
        @chunks = []
    end

    def load
        return self if @loaded

        parse_journal

        @loaded = true
        self
    end

    def get_chunk(idx)
        @chunks[idx || 0]
    end

    private

    def parse_journal
        started = false
        heading = nil
        lines = []

        File.foreach(@file) do |line|
            line = line.chomp
            next if line.strip.empty?

            if !started
                next unless line.start_with?("## ")
                started = true
                heading = line[3..].strip
                lines = [clean_line(line)]
                next
            end

            if line.start_with?("## ")
                push_chunk(heading, lines)
                heading = line[3..].strip
                lines = [clean_line(line)]
                next
            end

            next if line.lstrip.start_with?("<")

            lines << clean_line(line)
        end

        push_chunk(heading, lines) if started
    end

    def push_chunk(heading, lines)
        return if SKIP_HEADINGS.any? { |k| heading.include?(k) }
        return if lines.length < 3

        @chunks << lines.join("\n")
    end

    def clean_line(line)
        line.gsub(/\[([^\]]+)\]\(([^\)]+)\)/, '\\1')
    end
end
