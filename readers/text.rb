
class TextReader
    attr_accessor :file, :chunks

    def initialize(file)
        @file = file
        @loaded = false
        @chunks = []
    end

    MAX_WORDS = 7900

    def load
        return self if @loaded

        lines = []
        boundary = 0
        words = 0
        in_frontmatter = false

        File.foreach(@file) do |line|
            stripped = line.strip

            if in_frontmatter
                if stripped == '---' || stripped == '...'
                    in_frontmatter = false
                end
                next
            elsif stripped == '---'
                in_frontmatter = true
                next
            end

            if (line.start_with?('- ') && line.include?(':')) || line.start_with?('  - [[')
                next
            elsif line.start_with?('<')
                next
            end

            if stripped == '---'
                boundary = lines.length
                next
            end

            lines << line
            words += count_tokens(stripped)

            boundary = lines.length if stripped.empty?

            if words >= MAX_WORDS
                split_at = boundary.zero? ? lines.length : boundary
                @chunks << lines[0, split_at].join
                lines = lines[split_at..-1] || []
                words = lines.sum { |l| count_tokens(l.strip) }
                boundary = 0
            end
        end

        @chunks << lines.join unless lines.empty?
        @loaded = true

        self
    end

    def count_tokens(str)
        return 0 if str.nil? || str.empty?
        if str.match?(/\s/)
            str.split(/\s+/).length
        else
            str.length
        end
    end

    def get_chunk(idx)
        @chunks[idx || 0]
    end
end