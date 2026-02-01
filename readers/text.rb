
class TextReader
    include ChunkUtils

    attr_accessor :file, :chunks

    def initialize(file)
        @file = file
        @loaded = false
        @chunks = []
    end

    MAX_WORDS = 1000
    MIN_WORDS = 10

    def load
        return self if @loaded
        unless File.exist?(@file)
            @loaded = true
            return self
        end

        begin
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
        rescue Errno::ENOENT
            # file was removed after existence check; skip loading
        end

        @chunks = filter_small_chunks(@chunks, MIN_WORDS)
        @loaded = true

        self
    end

    def get_chunk(idx)
        return nil if @chunks.empty?
        index = idx || 0
        return nil if index >= @chunks.length || index < -@chunks.length
        @chunks[index]
    end
end
