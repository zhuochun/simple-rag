
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
        File.foreach(@file) do |line|
            if line.start_with?(/- .+:/) || line.start_with?('  - [[') # yaml like
                next
            elsif line.start_with?('<') # html like
                next
            else
                chunk << line unless line.strip.empty?
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