
class TextReader
    attr_accessor :file, :chunks

    def initialize(file)
        @file = file
        @loaded = false
        @chunks = []
    end

    def load
        return self if @loaded

        chunk = ""
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

            if line.start_with?('- ') && line.include?(':') || line.start_with?('  - [[')
                next
            elsif line.start_with?('<')
                next
            else
                chunk << line unless stripped.empty?
            end
        end

        @chunks << chunk
        @loaded = true

        self
    end

    def get_chunk(idx)
        @chunks[idx || 0]
    end
end