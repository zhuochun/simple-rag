class JournalReader
    SKIP_HEADINGS = ["\u7CBE\u529B", "\u611F\u6069"]
    include ChunkUtils

    MAX_WORDS = 1000
    MIN_WORDS = 10

    attr_accessor :file, :chunks

    def initialize(file)
        @file = file
        @loaded = false
        @chunks = []
    end

    def load
        return self if @loaded

        unless File.exist?(@file)
            @loaded = true
            return self
        end

        begin
            parse_journal
        rescue Errno::ENOENT
            @loaded = true
            return self
        end

        @loaded = true
        self
    end

    def get_chunk(idx)
        return nil if @chunks.empty?
        index = idx || 0
        return nil if index >= @chunks.length || index < -@chunks.length
        @chunks[index]
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

        content = lines.join("\n")
        split_chunk_by_tokens(content, MAX_WORDS).each do |chunk|
            @chunks << chunk
        end
        @chunks = filter_small_chunks(@chunks, MIN_WORDS)
    end

    def clean_line(line)
        line.gsub(/\[([^\]]+)\]\(([^\)]+)\)/, '\\1')
    end
end
